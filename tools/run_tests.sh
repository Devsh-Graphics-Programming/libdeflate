#!/bin/bash
#
# Test script for libdeflate
#
#	Usage: ./tools/run_tests.sh [TESTGROUP]... [-TESTGROUP]...
#
# By default all tests are run, but it is possible to explicitly include or
# exclude specific test groups.
#

set -eu
cd "$(dirname "$0")/.."

TESTGROUPS="$@"
if [ ${#TESTGROUPS} -eq 0 ]; then
	TESTGROUPS=(all)
fi

SMOKEDATA="${SMOKEDATA:=$HOME/data/smokedata}"
if [ ! -e "$SMOKEDATA" ]; then
	echo "SMOKEDATA (value: $SMOKEDATA) does not exist.  Set the" \
	      "environmental variable SMOKEDATA to a file to use in" \
	      "compression/decompression tests." 1>&2
	exit 1
fi

NDKDIR="${NDKDIR:=/opt/android-ndk}"

FILES=("$SMOKEDATA" ./tools/exec_tests.sh benchmark test_checksums)
EXEC_TESTS_CMD="WRAPPER= SMOKEDATA=\"$(basename $SMOKEDATA)\" sh exec_tests.sh"
NPROC=$(grep -c processor /proc/cpuinfo)

###############################################################################

rm -f run_tests.log
exec >  >(tee -ia run_tests.log)
exec 2> >(tee -ia run_tests.log >&2)

TESTS_SKIPPED=
log_skip() {
	log "[WARNING, TEST SKIPPED]: $@"
	TESTS_SKIPPED=1
}

log() {
	echo "[$(date)] $@"
}

run_cmd() {
	log "$@"
	"$@" > /dev/null
}

test_group_enabled() {
	local status=1 group
	for group in "${TESTGROUPS[@]}"; do
		if [ $group = $1 ]; then
			status=0 # explicitly included
			break
		fi
		if [ $group = -$1 ]; then
			status=1 # explicitly excluded
			break
		fi
		if [ $group = all ]; then # implicitly included
			status=0
		fi
	done
	if [ $status -eq 0 ]; then
		log "Starting test group: $1"
	fi
	return $status
}

###############################################################################

native_build_and_test() {
	make "$@" -j$NPROC all test_programs > /dev/null
	WRAPPER="$WRAPPER" SMOKEDATA="$SMOKEDATA" sh ./tools/exec_tests.sh \
			> /dev/null
}

native_tests() {
	test_group_enabled native || return 0
	local compiler cflags compilers=(gcc clang)
	shopt -s nullglob
	compilers+=(/usr/bin/gcc-[0-9]*)
	compilers+=(/opt/gcc*/bin/gcc)
	shopt -u nullglob
	for compiler in ${compilers[@]}; do
		for cflags in "" "-march=native" "-m32"; do
			if [ "$compiler" = "/usr/bin/gcc-4.8" -a \
			     "$cflags" = "-m32" ]; then
				continue
			fi
			log "Running tests with CC=$compiler," \
				"CFLAGS=$cflags"
			WRAPPER= native_build_and_test \
				CC=$compiler CFLAGS="$cflags -Werror"
		done
	done

	log "Running tests with Valgrind"
	WRAPPER="valgrind --error-exitcode=100 --quiet" native_build_and_test

	log "Running tests with undefined behavior sanitizer"
	WRAPPER= native_build_and_test CC=clang CFLAGS="-fsanitize=undefined"
}

###############################################################################

android_build() {
	run_cmd ./tools/android_build.sh --ndkdir="$NDKDIR" "$@"
}

android_build_and_test() {
	android_build "$@"
	run_cmd adb push "${FILES[@]}" /data/local/tmp/

	# Note: adb shell always returns 0, even if the shell command fails...
	log "adb shell \"cd /data/local/tmp && $EXEC_TESTS_CMD\""
	adb shell "cd /data/local/tmp && $EXEC_TESTS_CMD" | \
		grep -q "exec_tests finished successfully"
}

android_tests() {
	local compiler

	test_group_enabled android || return 0
	if [ ! -e $NDKDIR ]; then
		log_skip "Android NDK was not found in NDKDIR=$NDKDIR!" \
		         "If you want to run the Android tests, set the" \
			 "environmental variable NDKDIR to the location of" \
			 "your Android NDK installation"
		return 0
	fi

	if ! type -P adb > /dev/null; then
		log_skip "adb (android-tools) is not installed"
		return 0
	fi

	if (( $(adb devices | wc -l) < 3)); then
		log_skip "No Android device is currently attached"
		return 0;
	fi

	for compiler in gcc clang; do
		android_build_and_test --arch=arm --compiler=$compiler

		android_build_and_test --arch=arm --compiler=$compiler \
				       --disable-neon

		# arm64: currently compiled but not run
		android_build --arch=arm64 --compiler=$compiler
	done
}

###############################################################################

mips_tests() {
	test_group_enabled mips || return 0
	if ! ping -c 1 dd-wrt > /dev/null; then
		log_skip "Can't run MIPS tests: dd-wrt system not available"
		return 0
	fi
	run_cmd ./tools/mips_build.sh
	run_cmd scp "${FILES[@]}" root@dd-wrt:
	run_cmd ssh root@dd-wrt "$EXEC_TESTS_CMD"
}

###############################################################################

windows_tests() {
	local arch

	test_group_enabled windows || return 0

	# Windows: currently compiled but not run
	for arch in i686 x86_64; do
		local compiler=${arch}-w64-mingw32-gcc
		if ! type -P $compiler > /dev/null; then
			log_skip "$compiler not found"
			continue
		fi
		run_cmd make CC=$compiler CFLAGS=-Werror -j$NPROC \
			all test_programs
	done
}

###############################################################################

static_analysis_tests() {
	test_group_enabled static_analysis || return 0
	if ! type -P scan-build > /dev/null; then
		log_skip "clang static analyzer (scan-build) not found"
		return 0
	fi
	run_cmd scan-build --status-bugs make -j$NPROC all test_programs
}

###############################################################################

log "Starting libdeflate tests"
log "	TESTGROUPS=(${TESTGROUPS[@]})"
log "	SMOKEDATA=$SMOKEDATA"
log "	NDKDIR=$NDKDIR"

native_tests
android_tests
mips_tests
windows_tests
static_analysis_tests

if [ -n "$TESTS_SKIPPED" ]; then
	log "No tests failed, but some tests were skipped.  See above."
else
	log "All tests passed!"
fi
