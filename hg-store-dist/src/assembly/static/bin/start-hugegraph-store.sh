#!/bin/bash

#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements. See the NOTICE file distributed with this
# work for additional information regarding copyright ownership. The ASF
# licenses this file to You under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#

function abs_path() {
    SOURCE="${BASH_SOURCE[0]}"
    while [ -h "$SOURCE" ]; do
        DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
        SOURCE="$(readlink "$SOURCE")"
        [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
    done
    echo "$( cd -P "$( dirname "$SOURCE" )" && pwd )"
}

BIN=$(abs_path)
TOP="$(cd "$BIN"/../ && pwd)"
CONF="$TOP/conf"
LIB="$TOP/lib"
LOGS="$TOP/logs"
OUTPUT=${LOGS}/hugegraph-store-server.log
PID_FILE="$BIN/pid"
arch=`arch`
echo "arch --> ", ${arch}
#if [[ $arch =~ "aarch64" ]];then
#	  export LD_PRELOAD="$TOP/bin/libjemalloc_aarch64.so"
#else
export LD_PRELOAD="$TOP/bin/libjemalloc.so"
#fi

##pd/store max user processes, ulimit -u
export PROC_LIMITN=20480
##pd/store open files, ulimit -n
export FILE_LIMITN=1024000

function check_evn_limit() {
    local limit_check=$(ulimit -n)
    if [ ${limit_check} -lt ${FILE_LIMITN} ]; then
        echo -e "${BASH_SOURCE[0]##*/}:${LINENO}:\E[1;32m ulimit -n 可以打开的最大文件描述符数太少,需要(${FILE_LIMITN})!! \E[0m"
        return 1
    fi
    limit_check=$(ulimit -u)
    if [ ${limit_check} -lt ${PROC_LIMITN} ]; then
        echo -e "${BASH_SOURCE[0]##*/}:${LINENO}:\E[1;32m ulimit -u  用户最大可用的进程数太少,需要(${PROC_LIMITN})!! \E[0m"
        return 2
    fi
    return 0
}

check_evn_limit
if [ $? != 0 ]; then
    exit 8
fi

if [ -z "$GC_OPTION" ];then
  GC_OPTION=""
fi
if [ -z "$USER_OPTION" ];then
  USER_OPTION=""
fi

while getopts "g:j:v" arg; do
    case ${arg} in
        g) GC_OPTION="$OPTARG" ;;
        j) USER_OPTION="$OPTARG" ;;
        v) VERBOSE="verbose" ;;
        ?) echo "USAGE: $0 [-g g1] [-j xxx] [-v]" && exit 1 ;;
    esac
done




. "$BIN"/util.sh

mkdir -p ${LOGS}

# The maximum and minium heap memory that service can use
MAX_MEM=$((36 * 1024))
MIN_MEM=$((36 * 1024))
EXPECT_JDK_VERSION=11

# Change to $BIN's parent
cd ${TOP}

# Find Java
if [ "$JAVA_HOME" = "" ]; then
    JAVA="java"
else
    JAVA="$JAVA_HOME/bin/java"
fi

# check jdk version
JAVA_VERSION=$($JAVA -version 2>&1 | awk 'NR==1{gsub(/"/,""); print $3}'  | awk -F'_' '{print $1}')
if [[ $? -ne 0 || $JAVA_VERSION < $EXPECT_JDK_VERSION ]]; then
    echo "Please make sure that the JDK is installed and the version >= $EXPECT_JDK_VERSION"  >> ${OUTPUT}
    exit 1
fi

# Set Java options
if [ "$JAVA_OPTIONS" = "" ]; then
    XMX=$(calc_xmx $MIN_MEM $MAX_MEM)
    if [ $? -ne 0 ]; then
        echo "Failed to start HugeGraphStoreServer, requires at least ${MIN_MEM}m free memory" \
             >> ${OUTPUT}
        exit 1
    fi
     JAVA_OPTIONS="-Xms${MIN_MEM}m -Xmx${XMX}m -XX:MetaspaceSize=256M  -XX:+UseG1GC  -XX:+ParallelRefProcEnabled -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${LOGS} ${USER_OPTION} "
    # JAVA_OPTIONS="-Xms${MIN_MEM}m -Xmx${XMX}m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${LOGS} ${USER_OPTION}"

    # Rolling out detailed GC logs
    JAVA_OPTIONS="${JAVA_OPTIONS} -Xlog:gc=info:file=./logs/gc.log:tags,uptime,level:filecount=3,filesize=100m "
fi

# Using G1GC as the default garbage collector (Recommended for large memory machines)
case "$GC_OPTION" in
    g1)
        echo "Using G1GC as the default garbage collector"
        JAVA_OPTIONS="${JAVA_OPTIONS} -XX:+UseG1GC -XX:+ParallelRefProcEnabled \
                      -XX:InitiatingHeapOccupancyPercent=50 -XX:G1RSetUpdatingPauseTimePercent=5"
        ;;
    "") ;;
    *)
        echo "Unrecognized gc option: '$GC_OPTION', only support 'g1' now" >> ${OUTPUT}
        exit 1
esac

JVM_OPTIONS="-Dlog4j.configurationFile=${CONF}/log4j2.xml -Dfastjson.parser.safeMode=true"
#if [ "${JMX_EXPORT_PORT}" != "" ] && [ ${JMX_EXPORT_PORT} -ne 0 ] ; then
#  JAVA_OPTIONS="${JAVA_OPTIONS} -javaagent:${LIB}/jmx_prometheus_javaagent-0.16.1.jar=${JMX_EXPORT_PORT}:${CONF}/jmx_exporter.yml"
#fi

if [ $(ps -ef|grep -v grep| grep java|grep -cE ${CONF}) -ne 0 ]; then
   echo "HugeGraphStoreServer is already running..."
   exit 0
fi

echo "Starting HugeGraphStoreServer..."

exec ${JAVA} ${JVM_OPTIONS} ${JAVA_OPTIONS} -jar -Dspring.config.location=${CONF}/application.yml \
    ${LIB}/hugegraph-store-*.jar >> ${OUTPUT} 2>&1 &

PID="$!"
# Write pid to file
echo "$PID" > "$PID_FILE"
echo "[+pid] $PID"
