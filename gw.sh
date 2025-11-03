#!/bin/bash

#  (C) Copyright Dariusz Kowalczyk
#
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License Version 2 as
#  published by the Free Software Foundation.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.


PATH=/sbin:/usr/sbin/:/bin:/usr/bin:$PATH
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SCRIPT_NAME="$(basename "$0")"
GW_CONF_PATH="${SCRIPT_DIR}/gw.conf"
GW_FUNCTIONS_PATH="$SCRIPT_DIR/gwfunctions.sh"
current_time=$(date +"%F %T.%3N%:z")

MESSAGE="Program must be run as root"
if [[ $EUID -ne 0 ]]; then
    logger -p "info" -t "${SCRIPT_NAME}" "${MESSAGE}"
    echo "${MESSAGE}"
    exit 1
fi

FW_CONFIG_TEMP_DIR=$(mktemp -d -p /dev/shm/ GW_CONFIG.XXXX)
trap 'rm -rf ${GW_CONFIG_TEMP_DIR}' INT TERM EXIT

#Load fw.sh config file
MESSAGE="Can not load gw.conf"
if ! source "${GW_CONF_PATH}"; then
    logger -p error -t "${SCRIPT_NAME}" "${MESSAGE}"
    echo "$MESSAGE"
    exit 1
fi

if [ "$DEBUG" == "no" ]; then
    logdir="/dev"
    logfile="null"
fi

#Load fwfunction
MESSAGE="Can not load gwfunctions.sh"
if ! source "${FW_FUNCTIONS_PATH}"; then
    logger -p error -t "${SCRIPT_NAME}" "${MESSAGE}"
    echo "${MESSAGE}"
    exit 1
fi


####Makes necessary directories and files####
[[ -f "$logdir"/"$logfile" ]] || touch "$logdir"/"$logfile"
[[ -d /run/gw-sh/ ]] || mkdir /run/gw-sh
[[ -f /run/gw-sh/maintenance.pid ]] || echo 0 > /run/gw-sh/maintenance.pid
[[ -d "$confdir" ]] || mkdir -p "$confdir"
[[ -d "$oldconfdir" ]] || mkdir -p "$oldconfdir"

for param in $confdir $oldconfdir; do
    [[ -f "$param"/"$nat_11_file" ]] || touch "$param"/"$nat_11_file"
    [[ -f "$param"/"$nat_1n_ip_file" ]] || touch "$param"/"$nat_1n_ip_file"
    [[ -f "$param"/"$public_ip_file" ]] || touch "$param"/"$public_ip_file"
    [[ -f "$param"/"$routed_nets_file" ]] || touch "$param"/"$routed_nets_file"
    [[ -f "$param"/"$blacklist_file" ]] || touch "$param"/"$blacklist_file"
    [[ -f "$param"/"$lan_banned_dst_ports_file" ]] || touch "$param"/"$lan_banned_dst_ports_file"
    [[ -f "$param"/"$shaper_file" ]] || touch "$param"/"$shaper_file"
    [[ -f "$param"/"$dhcp_conf_file" ]] || touch "$param"/"$dhcp_conf_file"
done


stop (){
    Log "info" "Trying Gateway Stopping"
    fw_cron stop
    dhcpd_cmd stop
    shaper_cmd stop
    static_routing_down
    firewall_down
    destroy_all_hashtables
    Log "info" "Gateway Stoped successfully"
}

start (){
    #tuned-adm profile network-latency
    Log "info" "Trying Gateway Starting"
    stop > /dev/null 2>&1
    static_routing_up
    create_fw_hashtables
    load_fw_hashtables
    firewall_up
    shaper_cmd start
    dhcpd_cmd start
    fw_cron start
    Log "info" "gateway Started successfully"
}

newreload (){
    Log "info" "Gateway reloading"
    load_fw_hashtables
    modify_nat11_fw_rules
    modify_nat1n_fw_rules
    shaper_cmd restart
    dhcpd_cmd restart
    Log "info" "Gateway reloaded successfully"
}

lmsd (){
    dburl="mysql -s -u $lms_dbuser $lms_db -e \"select reload from hosts where id=4\""
    lmsd_status=$($exec_cmd $dburl| grep -v reload)
    if [ "$lmsd_status" = 1 ]; then
        Log "info" "Host reload status has been set"
        lmsd_reload
        get_config
        newreload
    fi
}

maintenance-on (){
    Log "info" "Trying Gateway maintenance on"
    mpid=$(cat /run/fw-sh/maintenance.pid)
    if [ "$mpid" = 1 ]; then
        Log "info" "Gateway maintenance is allready on"
        Log "info" "To exit from maintenance mode run: gw.sh maintenance-off"
        exit
    else
        ip link set dev "$MGMT" up && { echo 1 > /run/gw-sh/maintenance.pid; Log "info" "Gateway maintenance is on"; } || { Log "error" "Can not set device "$MGMT" up"; exit 1; }
        #stop
        #ip link set dev "$LAN" down
        #ip link set dev "$WAN" down
    fi

}

maintenance-off (){
    Log "info" "Trying Gateway maintenance off"
    mpid=$(cat /run/fw-sh/maintenance.pid)
    if [ "$mpid" = 0 ]; then
        Log "info" "Gateway maintenance is allready off"
        exit
    else
        #ip link set dev "$WAN" up || { Log "error" "Can not set device $WAN up"; exit 1; }
        #ip link set dev "$LAN" up || { Log "error" "Can not set device $LAN up"; exit 1; }
        sleep 5
        #start
        ip link set dev "$MGMT" down && { echo 0 > /run/gw-sh/maintenance.pid; Log "info" "Gateway maintenance is off"; } || { Log "error" "Can not set device "$MGMT" down"; }
    fi
}



#####Main program####
case "$1" in

    'start')
        start
    ;;
    'stop')
        stop
    ;;
    'status')
        fwstatus
    ;;
    'restart')
        stop
        start
    ;;
    'reload')
        newreload
    ;;
    'lmsd')
        lmsd
    ;;
    'shaper_stop')
        shaper_cmd stop
    ;;
    'shaper_start')
        shaper_cmd start
    ;;
    'shaper_reload')
        get_shaper_config
        shaper_reload
    ;;
    'shaper_stats')
        shaper_cmd stats
    ;;
    'shaper_status')
        shaper_cmd status
    ;;
    'maintenance-on')
        maintenance-on
    ;;
    'maintenance-off')
        maintenance-off
    ;;
    *)
       Log "info" "Script running without parameter"
       echo -e "\nUsage: gw.sh start|stop|restart|reload|status|lmsd|shaper_stop|shaper_start|shaper_restart|shaper_stats|shaper_status|maintenance-on|maintenance-off"
    ;;
esac
