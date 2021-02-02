#! /bin/bash -eu

port=$1
stty -F $port 9600

read_bytes() {
   read -N $1 -t 1 < $port; echo $REPLY
}

setup_listen() {
    coproc read_bytes $1
    sleep 0.01
}

send_command() {
   setup_listen $2;
    echo -en $1 > $port
    read var <&"${COPROC[0]}";
    echo "$var"
}

get_status() {
    power=`send_command "~00150 1\r" 16 | cut -c 3`
    if [ "$power" == "0" ]; then
        power="Standby"
    elif [ "$power" == "1" ]; then
        power="Power On"
    fi

   echo "$power"

}

get_lamp_timer() {
    hours=$((10#`send_command "~00150 1\r" 16 | cut -c 4-8`))
    echo "$hours"
}

get_error() {
    echo "No Error"
}

