#! /bin/bash -eu

exit_with_error() {
    >&2 echo "$1"
    exit 1
}

if ! `jq --version > /dev/null 2>&1` ; then
    exit_with_error "Please install missing dependencies: jq"
fi

if ! `xxd -v > /dev/null 2>&1` ; then
    exit_with_error "Please install missing dependencies: xxd"
fi

if [ $# -lt 1 ]; then
    exit_with_error "Missing config file parameter: $0 <config-file>"
fi

dir=/opt/ha-projector-status/

mkdir -p $dir
cp -r projectors $dir
cp $1 $dir/config.json
cp run.sh $dir
systemctl stop ha-projector-status || true
cp systemd/ha-projector-status.service /etc/systemd/system
systemctl enable ha-projector-status
systemctl start ha-projector-status
systemctl status ha-projector-status
