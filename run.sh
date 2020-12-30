#! /usr/bin/env -S bash -eu

exit_with_error() {
    >&2 echo "$1"
    exit 1
}

valid_projectors() {
    echo `ls projectors/ | sed 's/.sh//' | tr '\n' ' '`
}

sample_json() {
    cat config/sample.json
}

exit_with_usage() {
    >&2 echo "$1"
    echo ""
    echo "Usage:"
    echo "$0 <config>"\
    echo "where <config> is the path to a configuration json with contents like:"
    echo "`sample_json`"
    exit 1
}

if ! `jq --version > /dev/null 2>&1` ; then
    exit_with_error "Please install missing dependencies: jq"
fi

if ! `xxd -v > /dev/null 2>&1` ; then
    exit_with_error "Please install missing dependencies: xxd"
fi

if [ $# -lt 1 ]; then
    exit_with_usage "Missing config argument"
fi

cfg=$1

get_parameter() {
    prm=`jq -re "$1" $cfg`
    if [[ ! $? -eq 0 ]]; then
        exit_with_error "Config file missing \"$1\""
    fi

    echo "$prm"
}

projector=`get_parameter '.projector'`
port=`get_parameter '.port'`
ha_pwd=`get_parameter '.ha_pwd'`
ha_pwd=`get_parameter '.ha_pwd'`
ha_base_url=`get_parameter '.ha_base_url'`

if [ -z "`valid_projectors | grep $projector`" ]; then
    exit_with_error "Invalid projector selection \"$projector\", must be one of: `valid_projectors`"
fi

source "projectors/$projector.sh" $port

while true; do
    status=""
    while [ "$status" == "" ]; do
        status=`get_status`
    done

    error=""
    while [ "$error" == "" ]; do
        error=`get_error`
    done

    curl -X POST -H "x-ha-access: $ha_pwd" \
        -H "Content-Type: application/json" \
        -d '{"state": "'"$status"'", "attributes": {"friendly_name": "Projector State", "icon": "mdi:projector"}}' \
        $ha_base_url.projector_state

    curl -X POST -H "x-ha-access: $ha_pwd" \
        -H "Content-Type: application/json" \
        -d '{"state": "'"$error"'", "attributes": {"friendly_name": "Projector Error", "icon": "mdi:alert-circle"}}' \
        $ha_base_url.projector_error

    if [ "$status" == "Standby" ]; then
        sleep 30
        continue;
    fi

    lamp_timer=`get_lamp_timer`
    if [ "$lamp_timer" != "0" ]; then
        echo Lamp Timer: $lamp_timer Hours

        curl -X POST -H "x-ha-access: $ha_pwd" \
            -H "Content-Type: application/json" \
            -d '{"state": "'"$lamp_timer"'", "attributes": {"unit_of_measurement": "Hours", "friendly_name": "Projector Lamp Timer", "icon": "mdi:lightbulb-on"}}' \
            $ha_base_url.projector_lamp_timer
    fi

    sleep 5
done