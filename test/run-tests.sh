#!/bin/bash

set -o pipefail

usage()
{
	cat <<EOF
usage: ${0##*/} [-h] [-b PATTERN] [-c] [-i PATTERN] [-j JOBS] [-n] [-u PATTERN]

optional arguments:
  -h              show this help message and exit
  -b PATTERN      Only execute black box tests matching PATTERN
  -c TYPE         Create coverage report (html, xml)
  -i PATTERN      Only execute integration tests matching PATTERN
  -j JOBS         Run JOBS tests in parallel (requires GNU parallel)
  -u PATTERN      Only execute unit tests matching PATTERN
EOF
}

run_test()
{
	local ret LOGFILE=$(mktemp)
	local test_name="${1#*:}"

	{
		echo "======================================================================"
		echo "Test: $1"
	} > "$LOGFILE"

	case "${1%%:*}" in
		unit)
			pushd unit > /dev/null
			echo -n "  [unit]        ${test_name%%.py} ... "
			if $RUN_PYTHON3_COV -m unittest -v $test_name >>"$LOGFILE" 2>&1 ; then
				echo "ok"
				ret=0
			else
				echo "FAIL (log follows...)"
				ret=1
				cat -n "$LOGFILE"
			fi
			popd > /dev/null
			;;
		black-box)
			pushd black-box > /dev/null
			echo -n "  [blackbox]    $test_name ... "
			(
				set -o pipefail
				set -ex
				cd "$test_name"
				. run.sh 2>&1 | tee log.txt
			) >>"$LOGFILE" 2>&1

			ret=$?
			if [[ $ret -eq 240 ]] ; then
				echo "skipped"
				ret=0
			elif [[ $ret -ne 0 ]] ; then
				echo "FAIL (exit $ret, log follows...)"
				cat -n "$LOGFILE"
				ret=1
			else
				echo "ok"
			fi
			popd > /dev/null
			;;
		integration)
			pushd integration/$test_name > /dev/null
			echo -n "  [integration] $test_name ... "
			if $RUN_PYTHON3 run.py >>"$LOGFILE" 2>&1 ; then
				echo "ok"
				ret=0
			else
				echo "FAIL (log follows...)"
				ret=1
				cat -n "$LOGFILE"
			fi
			popd > /dev/null
			;;
		*)
			echo "INTERNAL ERROR!"
			;;
	esac

	cat "$LOGFILE" >> log.txt
	rm "$LOGFILE"
	return $ret
}

# Remove all GIT_ variables from environment. They will be set when running
# this script from "git rebase --exec" and blow up the git related tests.
unset "${!GIT_@}"

# move to root directory
cd "${0%/*}/.."
. ./test/test-lib.sh
export PATH="$PWD:$PATH"

# determine test environment
if [[ $(uname -o) == Msys ]] ; then
	RUN_PYTHON3=python
	case "$(python -c "import sys; print(sys.platform)")" in
		win32)
			TEST_ENVIRONMENT=win32
			;;
		msys | cygwin)
			TEST_ENVIRONMENT=msys
			;;
		*)
			echo "Unknown MSYS environment!"
			exit 1
			;;
	esac
else
	RUN_PYTHON3=python3
	TEST_ENVIRONMENT=posix
fi

COVERAGE=
FAILED=0
RUN_JOBS=
unset RUN_UNITTEST_PAT
unset RUN_BLACKBOX_PAT
unset RUN_INTEGRATION_PAT
export PYTHONDEVMODE=1
export PYTHONASYNCIODEBUG=1
export PYTHONWARNINGS=error
if [[ $($RUN_PYTHON3 --version) = "Python 3.9.7" ]] ; then
	# Stupid workaround for https://bugs.python.org/issue45097
	# Just ignore all deprecation warnings. To add insult to injury we
	# can't just ignore anything caused by asyncio because the full pacakge
	# name must be given in PYTHONWARNINGS.
	PYTHONWARNINGS+=",ignore::DeprecationWarning"
fi

# option processing
while getopts ":hb:c:i:j:u:" opt; do
	case $opt in
		h)
			usage
			exit 0
			;;
		b)
			RUN_BLACKBOX_PAT="$OPTARG"
			;;
		c)
			case "$OPTARG" in
				html|xml)
					COVERAGE="$OPTARG"
					;;
				*)
					echo "Invalid coverage format" >&2
					exit 1
					;;
			esac
			;;
		i)
			RUN_INTEGRATION_PAT="$OPTARG"
			;;
		j)
			RUN_JOBS="$OPTARG"
			;;
		u)
			RUN_UNITTEST_PAT="$OPTARG"
			;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			exit 1
			;;
	esac
done

# check if python coverage is installed if coverage is required
if [[ -z $COVERAGE ]] ; then
	:
elif type -fp coverage3 >/dev/null; then
	RUN_COVERAGE=coverage3
elif type -fp python3-coverage >/dev/null; then
	RUN_COVERAGE=python3-coverage
else
	echo "Coverage requeted but coverage3 is not installed" >&2
	echo "Try 'python3 -m pip install coverage'..." >&2
	exit 1
fi

RUN_PYTHON3_COV="$RUN_PYTHON3"
if [[ -n $RUN_COVERAGE ]] ; then
    # make sure coverage is installed in the current environment
    if $RUN_PYTHON3 -c "import coverage" 2>/dev/null; then
        export COVERAGE_SOURCES="$PWD/pym"
	export COVERAGE_OUTPUT="$PWD/test/.coverage"
	export COVERAGE_PROCESS_START="$PWD/test/subprocess.coveragerc"
        RUN_PYTHON3_COV="$RUN_COVERAGE run --rcfile=$PWD/test/unittest.coveragerc"
    else
        echo "coverage3 is installed but not usable!" >&2
	exit 1
    fi
fi

# execute everything if nothing was specified
if [[ -z ${RUN_UNITTEST_PAT+isset} && -z ${RUN_BLACKBOX_PAT+isset} &&
      -z ${RUN_INTEGRATION_PAT+isset} ]] ; then
	RUN_BLACKBOX_PAT='*'
	RUN_UNITTEST_PAT='*'
	RUN_INTEGRATION_PAT='*'
else
	: "${RUN_BLACKBOX_PAT=}"
	: "${RUN_UNITTEST_PAT=}"
	: "${RUN_INTEGRATION_PAT=}"
fi

# go to tests directory
pushd test > /dev/null

# remove stale coverage data
[[ -z $COVERAGE ]] || rm .coverage.* || true

# gather tests
RUN_TEST_NAMES=( )
if [[ -n "$RUN_UNITTEST_PAT" ]] ; then
	pushd unit > /dev/null
	for i in test_*.py ; do
		if [[ "${i%%.py}" == $RUN_UNITTEST_PAT ]] ; then
			RUN_TEST_NAMES+=( "unit:$i" )
		fi
	done
	popd > /dev/null
fi
if [[ -n "$RUN_BLACKBOX_PAT" ]] ; then
	pushd black-box > /dev/null
	for i in * ; do
		if [[ -d $i && -e "$i/run.sh" && "$i" == $RUN_BLACKBOX_PAT ]] ; then
			RUN_TEST_NAMES+=( "black-box:$i" )
		fi
	done
	popd > /dev/null
fi
if [[ -n "$RUN_INTEGRATION_PAT" ]] ; then
	pushd integration > /dev/null
	for i in * ; do
		if [[ -d $i && -e "$i/run.py" && "$i" == $RUN_INTEGRATION_PAT ]] ; then
			RUN_TEST_NAMES+=( "integration:$i" )
		fi
	done
	popd > /dev/null
fi

# execute all tests, possibly in parallel
if [[ ${#RUN_TEST_NAMES[@]} -eq 0 ]] ; then
	: # No tests matched
elif type -p parallel >/dev/null && [[ ${RUN_JOBS:-} != 1 ]] ; then
	export -f run_test
	export RUN_PYTHON3
	export RUN_PYTHON3_COV
	export TEST_ENVIRONMENT
	parallel ${RUN_JOBS:+-j $RUN_JOBS} run_test ::: \
	  "${RUN_TEST_NAMES[@]}" || : $((FAILED+=$?))
else
	for i in "${RUN_TEST_NAMES[@]}" ; do
		if ! run_test "$i" ; then
			: $((FAILED++))
		fi
	done
fi

popd > /dev/null

# collect coverage
if [[ -n $RUN_COVERAGE ]]; then
	unset PYTHONDEVMODE
	unset PYTHONASYNCIODEBUG
	unset PYTHONWARNINGS
	$RUN_COVERAGE combine --rcfile=test/subprocess.coveragerc
	$RUN_COVERAGE $COVERAGE --rcfile=test/subprocess.coveragerc
fi

if [[ $FAILED -gt 127 ]] ; then
   FAILED=127
fi
exit $FAILED
