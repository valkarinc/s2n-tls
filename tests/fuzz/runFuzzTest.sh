#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
#  http://aws.amazon.com/apache2.0
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.
#

# The timeout command sends a TERM and under normal circumstances returns
# exit code 124. We'll undo this later. 
set -e

usage() {
    echo "Usage: runFuzzTest.sh TEST_NAME FUZZ_TIMEOUT_SEC"
    exit 1
}

if [ "$#" -ne "3" ]; then
    usage
fi

TEST_NAME=$1
FUZZ_TIMEOUT_SEC=$2
CORPUS_UPLOAD_LOC=$3
MIN_TEST_PER_SEC="1000"
MIN_FEATURES_COVERED="100"

# Failures for negative tests on AFL can be ignored.
if [[ $TEST_NAME == *_negative_test && "$AFL_FUZZ" != "true" ]];
then
    EXPECTED_TEST_FAILURE=1
else
    EXPECTED_TEST_FAILURE=0
fi

ASAN_OPTIONS+="symbolize=1"
LSAN_OPTIONS+="log_threads=1"
UBSAN_OPTIONS+="print_stacktrace=1"
NUM_CPU_THREADS=$(nproc)
LIBFUZZER_ARGS+="-timeout=5 -max_len=4096 -print_final_stats=1 -jobs=${NUM_CPU_THREADS} -workers=${NUM_CPU_THREADS} -max_total_time=${FUZZ_TIMEOUT_SEC}"

TEST_SPECIFIC_OVERRIDES="${PWD}/LD_PRELOAD/${TEST_NAME}_overrides.so"
GLOBAL_OVERRIDES="${PWD}/LD_PRELOAD/global_overrides.so"

FUZZCOV_SOURCES="${S2N_ROOT}/api ${S2N_ROOT}/bin ${S2N_ROOT}/crypto ${S2N_ROOT}/error ${S2N_ROOT}/stuffer ${S2N_ROOT}/tls ${S2N_ROOT}/utils"

if [ -e $TEST_SPECIFIC_OVERRIDES ];
then
    export LD_PRELOAD="$TEST_SPECIFIC_OVERRIDES $GLOBAL_OVERRIDES"
else
    export LD_PRELOAD="$GLOBAL_OVERRIDES"
fi

FIPS_TEST_MSG=""
if [ -n "${S2N_TEST_IN_FIPS_MODE}" ];
then
    FIPS_TEST_MSG=" FIPS test"
fi

if [ ! -d "./corpus/${TEST_NAME}" ];
then
  printf "\033[33;1mWARNING!\033[0m ./corpus/${TEST_NAME} directory does not exist, feature coverage may be below minimum.\n\n"
fi

# Make directory if it doesn't exist
mkdir -p "./corpus/${TEST_NAME}"

ACTUAL_TEST_FAILURE=0

# Copy existing Corpus to a temp directory so that new inputs from fuzz tests runs will add new inputs to the temp directory.
# This allows us to minimize new inputs before merging to the original corpus directory.
# If s3 directory is specified, use corpuses stored in S3 bucket instead.
TEMP_CORPUS_DIR="$(mktemp -d)"
if [ "$CORPUS_UPLOAD_LOC" != "none" ]; then
    (
        # Clean the environment before copying corpuses from the S3 bucket.
        # The LD variables interferes with certificate validation when communicating with AWS S3.
        unset LD_PRELOAD
        unset LD_LIBRARY_PATH
        printf "Copying corpus files from S3 bucket...\n"
        aws s3 sync $CORPUS_UPLOAD_LOC/${TEST_NAME}/ "${TEMP_CORPUS_DIR}"
    )
else
    cp -r ./corpus/${TEST_NAME}/. "${TEMP_CORPUS_DIR}"
fi

# Run AFL instead of libfuzzer if AFL_FUZZ is set. Not compatible with fuzz coverage.
if [[ ${AFL_FUZZ} == "true" && ${FUZZ_COVERAGE} != "true" ]]; then
    unset LD_PRELOAD
    # See https://aflplus.plus/docs/env_variables/
    export AFL_NO_UI=true
    export AFL_HARDEN=true
    printf "Running AFL %-s %-40s for %5d sec... " "${FIPS_TEST_MSG}" ${TEST_NAME} ${FUZZ_TIMEOUT_SEC}
    mkdir -p results/${TEST_NAME}
    set +e
    timeout ${FUZZ_TIMEOUT_SEC} ${LIBFUZZER_INSTALL_DIR}/afl-fuzz -i corpus/${TEST_NAME} -o results/${TEST_NAME} -m none ./${TEST_NAME}  2>&1> ./results/${TEST_NAME}/console_output.log
    returncode=$?
    # See the timeout man page for specifics
    if [[ ${returncode} -ne 124 ]]; then
        printf "\033[33;1mWARNING!\033[0m AFL exited with an unexpected return value: %8d" ${returncode}
    fi
    set -e
    CRASH_COUNT=$(sed -n -e 's/^unique_crashes *: //p' ./results/${TEST_NAME}/fuzzer_stats)
    TEST_COUNT=$(sed -n -e 's/^execs_done *: //p' ./results/${TEST_NAME}/fuzzer_stats)
    FLOAT_TESTS_PER_SEC=$(sed -n -e 's/^execs_per_sec *: //p' ./results/${TEST_NAME}/fuzzer_stats)
    TESTS_PER_SEC=$(echo "($FLOAT_TESTS_PER_SEC+.5)/1"|bc)

    if [[ ${TESTS_PER_SEC} -lt 10 ]]; then
        printf "\033[33;1mWARNING!\033[0m %10d tests, only %6d tests per second; test is too slow.\n" ${TEST_COUNT} ${TESTS_PER_SEC}
    fi
    if [[ ${CRASH_COUNT} -gt 0 ]]; then
        ACTUAL_TEST_FAILURE=1
    fi
    if [[ ${ACTUAL_TEST_FAILURE} == ${EXPECTED_TEST_FAILURE} ]]; then
        printf "\033[32;1mPASSED\033[0m %8d tests, %.1f test/sec\n" ${TEST_COUNT} ${TESTS_PER_SEC}
        exit 0
    else
        printf "\033[31;1mFAILED\033[0m %10d tests, %6d unique crashes\n" ${TEST_COUNT} ${CRASH_COUNT}
        exit -1
    fi
else
    printf "Running %-s %-40s for %5d sec with %2d threads... " "${FIPS_TEST_MSG}" ${TEST_NAME} ${FUZZ_TIMEOUT_SEC} ${NUM_CPU_THREADS}
fi

# Setup and clean profile structure if FUZZ_COVERAGE is enabled, otherwise run as normal
if [[ "$FUZZ_COVERAGE" == "true" ]]; then
    mkdir -p "./profiles/${TEST_NAME}"
    rm -f ./profiles/${TEST_NAME}/*.profraw
    LLVM_PROFILE_FILE="./profiles/${TEST_NAME}/${TEST_NAME}.%p.profraw" ./${TEST_NAME} ${LIBFUZZER_ARGS} ${TEMP_CORPUS_DIR} > ${TEST_NAME}_output.txt 2>&1 || ACTUAL_TEST_FAILURE=1
else
    ./${TEST_NAME} ${LIBFUZZER_ARGS} ${TEMP_CORPUS_DIR} > ${TEST_NAME}_output.txt 2>&1 || ACTUAL_TEST_FAILURE=1
fi

TEST_INFO=$(
    grep -o "stat::number_of_executed_units: [0-9]*" ${TEST_NAME}_output.txt | \
    awk -v timeout=$FUZZ_TIMEOUT_SEC '{count += int($2); rate = int(count / timeout)} END {print count, "tests, " rate " test/sec"}' \
)
TESTS_PER_SEC=$(echo "$TEST_INFO" | cut -d ' ' -f 3)
FEATURE_COVERAGE=`grep -o "ft: [0-9]*" ${TEST_NAME}_output.txt | awk '{print $2}' | sort | tail -1`
TARGET_FUNCS=''
declare -i TARGET_TOTAL=0
declare -i TARGET_COV=0

# Outputs fuzz coverage results if the FUZZ_COVERAGE environment variable is set
# Coverage is overlayed on source code in ${TEST_NAME}_cov.html, and coverage statistics are available in ${TEST_NAME}_cov.txt
# If using LLVM version 9 or greater, coverage is output in LCOV format instead of HTML
# All files are stored in the s2n coverage directory
if [[ "$FUZZ_COVERAGE" == "true" ]]; then
    mkdir -p ${COVERAGE_DIR}/fuzz
    llvm-profdata merge -sparse ./profiles/${TEST_NAME}/*.profraw -o ./profiles/${TEST_NAME}/${TEST_NAME}.profdata
    llvm-cov report -instr-profile=./profiles/${TEST_NAME}/${TEST_NAME}.profdata ${S2N_ROOT}/lib/libs2n.so ${FUZZCOV_SOURCES} -show-functions > ${COVERAGE_DIR}/fuzz/${TEST_NAME}_cov.txt

    # Use LCOV format instead of HTML if the LLVM version we're using supports it
    if [[ $(grep -Eo "[0-9]*" <<< `llvm-cov --version` | head -1) -gt 8 ]]; then
        llvm-cov export -instr-profile=./profiles/${TEST_NAME}/${TEST_NAME}.profdata ${S2N_ROOT}/lib/libs2n.so ${FUZZCOV_SOURCES} -format=lcov > ${COVERAGE_DIR}/fuzz/${TEST_NAME}_cov.info
        genhtml -q -o ${COVERAGE_DIR}/html/${TEST_NAME} ${COVERAGE_DIR}/fuzz/${TEST_NAME}_cov.info
    else
        llvm-cov show -instr-profile=./profiles/${TEST_NAME}/${TEST_NAME}.profdata ${S2N_ROOT}/lib/libs2n.so ${FUZZCOV_SOURCES} -use-color -format=html > ${COVERAGE_DIR}/fuzz/${TEST_NAME}_cov.html
    fi

    # Extract target functions from test source
    TARGET_FUNCS=`grep -Pzo "(?<=/\* Target Functions: )[\w\s]*" ${TEST_NAME}.c | tr -d "\0"`

    # Find line coverage statistics for target functions
    if [[ ! -z "$TARGET_FUNCS" ]];
    then
        for TARGET in ${TARGET_FUNCS}
        do
            TARGET_TOTAL+=`sed -n "s/^.*${TARGET} .*% *\([0-9]*\) .*$/\1/p" ${COVERAGE_DIR}/fuzz/${TEST_NAME}_cov.txt`
            TARGET_COV+=`sed -n "s/^.*${TARGET} .*% *[0-9]* *\([0-9]*\) .*$/\1/p" ${COVERAGE_DIR}/fuzz/${TEST_NAME}_cov.txt`
        done
    fi
fi

if [ $ACTUAL_TEST_FAILURE == $EXPECTED_TEST_FAILURE ];
then
    printf "\033[32;1mPASSED\033[0m %s" "$TEST_INFO"

    # Output target function coverage percentage if target functions are defined and fuzzing coverage is enabled
    # Otherwise, print number of features covered
    if [[ "$FUZZ_COVERAGE" == "true" && ! -z "$TARGET_FUNCS" && "$EXPECTED_TEST_FAILURE" != 1 && "$TARGET_TOTAL" != 0 ]];
    then
        printf ", %6.2f%% target coverage" "$(( 10000 * ($TARGET_TOTAL - $TARGET_COV) / $TARGET_TOTAL ))e-2"
    else
        printf ", %5d features covered" $FEATURE_COVERAGE
    fi

    if [ $EXPECTED_TEST_FAILURE == 1 ];
    then
        # Clean up LibFuzzer corpus files if the test is negative.
        printf "\n"
        rm -f leak-* crash-*
    else
        # TEMP_CORPUS_DIR may contain many new inputs that only covers a small set of new branches. 
        # Instead of copying all new inputs to the corpus directory,  only copy back minimum number of new inputs that reach new branches.
        ./${TEST_NAME} -merge=1 "./corpus/${TEST_NAME}" "${TEMP_CORPUS_DIR}" > ${TEST_NAME}_results.txt 2>&1

        # Print number of new files and branches found in new Inputs (if any)
        RESULTS=`grep -Eo "[0-9]+ new files .*$" ${TEST_NAME}_results.txt | tail -1`
        printf ", ${RESULTS}\n"

        if [ "$TESTS_PER_SEC" -lt $MIN_TEST_PER_SEC ]; then
            printf "\033[33;1mWARNING!\033[0m ${TEST_NAME} is only ${TESTS_PER_SEC} tests/sec, which is below ${MIN_TEST_PER_SEC}/sec! Fuzz tests are more effective at higher rates.\n\n"
        fi

        COVERAGE_FAILURE_ALLOWED=0
        if grep -Fxq ${TEST_NAME} ./allowed_coverage_failures.cfg
        then
            COVERAGE_FAILURE_ALLOWED=1
        fi

        if [[ "$FEATURE_COVERAGE" -lt $MIN_FEATURES_COVERED && COVERAGE_FAILURE_ALLOWED -eq 0 ]]; then
            printf "\033[31;1mERROR!\033[0m ${TEST_NAME} only covers ${FEATURE_COVERAGE} features, which is below ${MIN_FEATURES_COVERED}! This may be due to missing corpus files or a bug.\n"
            exit -1;
        fi

        # Store generated corpus files in the S3 bucket.
        unset LD_PRELOAD
        unset LD_LIBRARY_PATH
        if [ "$CORPUS_UPLOAD_LOC" != "none" ]; then
            printf "Uploading corpus files to S3 bucket...\n"
            aws s3 sync ./corpus/${TEST_NAME}/ $CORPUS_UPLOAD_LOC/${TEST_NAME}/
        fi
    fi

else
    cat ${TEST_NAME}_output.txt
    printf "\033[31;1mFAILED\033[0m %s, %6d features covered\n" "$TEST_INFO" $FEATURE_COVERAGE
    exit -1
fi
