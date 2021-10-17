#! /bin/bash -eu

port=$1

stty -F $port 38400 cs8 -cstopb parenb -parodd raw

setup_listen() {
    coproc xxd -c8 -l8 -p $port
    (sleep 1; killall xxd -q) &
    sleep 0.01
}

get_status() {
    setup_listen;
    echo -en '\xA9\x01\x02\x01\x00\x00\x03\x9A' > $port;
    read var <&"${COPROC[0]}";
    result=`echo $var | cut -c 9-12`;
    if [ "$result" == "0000" ]; then
        status="Standby";
    elif [ "$result" == "0002" ]; then
        status="Starting Up";
    elif [ "$result" == "0003" ]; then
        status="Power On";
    elif [ "$result" == "0004" ]; then
        status="Cooling 1";
    elif [ "$result" == "0005" ]; then
        status="Cooling 2";
    elif [ "$result" == "0006" ]; then
        status="Saving Cooling 1";
    elif [ "$result" == "0007" ]; then
        status="Saving Cooling 2";
    elif [ "$result" == "0008" ]; then
        status="Saving Standby";
    elif [ "$result" != "" ]; then
        status="Unknown power status: $result";
    fi
    sleep 1
    echo "$status"
}

get_error() {
    setup_listen;
    echo -en '\xA9\x01\x01\x01\x00\x00\x01\x9A' > $port;
    read var <&"${COPROC[0]}";
    result=`echo $var | cut -c 9-12`;
    if [ "$result" == "0000" ]; then
        status="No Error";
    elif [ "$result" == "0001" ]; then
        status="Lamp Error";
    elif [ "$result" == "0002" ]; then
        status="Fan Error";
    elif [ "$result" == "0004" ]; then
        status="Cover Error";
    elif [ "$result" == "0008" ]; then
        status="Temp Error";
    elif [ "$result" != "" ]; then
        status="Unknown error status: $result";
    fi
    sleep 1
    echo "$status"
}

get_lamp_timer() {
    setup_listen;
    echo -en '\xA9\x01\x13\x01\x00\x00\x13\x9A' > $port;
    read var <&"${COPROC[0]}";
    result=`echo $var | cut -c 9-12`;
    timer=`echo $((16#$result))`
    sleep 1
    echo "$timer"
}
