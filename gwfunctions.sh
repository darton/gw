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


function Log {
    local message
    message="${*:2}"
    local level="$1"
    logger -p "user.${level}" -t gw.sh "${message}"
    if [[ "$DEBUG" == "true" || "$DEBUG" == "yes" ]]; then
        echo "${message}"
    fi
}

required_commands() {
  for cmd; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "Missing required command: $cmd" >&2
      echo "You can install it using: sudo apt|dnf install $cmd"  >&2
      return 1
    }
  done
}

check_interfaces_up() {
    for iface in "$@"; do
        if [[ ! -e "/sys/class/net/$iface/operstate" ]]; then
            return 1
        fi
        read -r state < "/sys/class/net/$iface/operstate"
        if [[ "$state" != "up" ]]; then
            return 1
        fi
    done
    return 0
}

compare_files_sha1() {

#   return 0 identical
#   return 1 different
#   return 2 not exist

    local file1="$1"
    local file2="$2"

    [[ ! -f "$file1" || ! -f "$file2" ]] && return 2

    local sum1 sum2
    sum1=$(sha1sum "$file1")
    sum1=${sum1%% *}

    sum2=$(sha1sum "$file2")
    sum2=${sum2%% *}

    [[ "$sum1" == "$sum2" ]] && return 0 || return 1
}

# Wrapper for systemctl that checks unit existence before executing an action
function systemctl_cmd {
    local action="$1"
    local unit="$2"

    # Validate input
    if [[ -z "$action" || -z "$unit" ]]; then
        Log error "Usage: systemctl_cmd <start|stop|restart|status|...> <unit>"
        return 3
    fi

    # Check if the unit exists
    if ! systemctl list-unit-files | grep -q "^${unit}"; then
        Log warn "Systemd unit '${unit}' does not exist"
        return 2
    fi

    # Execute the requested action
    if systemctl "$action" "$unit"; then
        Log info "systemctl ${action} ${unit} — OK"
        return 0
    else
        Log error "systemctl ${action} ${unit} — FAILED"
        return 1
    fi
}

function get_config {
    Log info "Connecting to LMS and downloading configuration files"
    $copy_cmd_url/* ${GW_CONFIG_TEMP_DIR} || { Log error "Can not download config files"; exit 1; }

    cd $confdir
    for FILENAME in *
    do
        mv $FILENAME $oldconfdir/$FILENAME || { Log error "Can not move old config file $FILENAME to $oldconfdir/$FILENAME"; exit 1; }
    done

    cp ${GW_CONFIG_TEMP_DIR}/* "$confdir"/ || { Log error "Can not copy new config files $FILENAME to cuurent config"; exit 1; }
    Log info "Get config OK"
}

function get_shaper_config {
    echo "The LMS generates a configuration for the Shaper"
    $exec_cmd "timeout 10 $lmsd -q -i $lmsd_shaper_instance -h $lms_dbhost:3306 -H $lmsd_host -u $lms_dbuser -p $lms_dbpwd -d $lms_db" || { Log error "Can not connect to database"; exit 1; }
    echo "Waiting a few seconds"
    sleep 5
    mv $confdir/$shaper_file $oldconfdir/$shaper_file
    echo "Connecting to the server and download the configuration file for Shaper"
    $copy_cmd_url/$shaper_file $confdir/ || { Log error "Can not download shaper config file - $shaper_file"; mv "$oldconfdir"/"$shaper_file" "$confdir"/; exit 1; }
    Log info "Get shaper config OK"
}

function lmsd_reload_all {
    echo "Reloading all lmsd instances on the remote machine"
    $exec_cmd "$lmsd -q -h $lms_dbhost:3306 -H $lmsd_host -u $lms_dbuser -p $lms_dbpwd -d $lms_db" || { Log error "Can not connect to database"; exit 1; }
    Log info "Waiting 10s for lmsd to create new configuration files"
    sleep 10
}

function dhcp_server_cmd {
    local arg="$1"
    local distro_id service

    # Pobierz ID dystrybucji
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        distro_id="$ID"
    fi

    declare -A dhcp_services=(
        [debian]="isc-dhcp-server"
        [ubuntu]="isc-dhcp-server"
        [fedora]="dhcpd"
        [centos]="dhcpd"
        [rhel]="dhcpd"
        [arch]="dhcpd4"
    )

    service="${dhcp_services[$distro_id]}"

    if [[ -n "$service" ]]; then
        systemctl_cmd "$arg" "$service"
    else
        Log warn "Unknown Linux distro: $distro_id"
    fi
}

function dhcpd_cmd {
    local arg="$1"
    if [ "$arg" = "start" ]; then
        dhcp_server_cmd start && Log info "The dhcpd server successfully started OK"
    elif [ "$arg" = "stop" ]; then
        dhcp_server_cmd stop && Log info "The dhcpd server successfully stopped OK"
    fi
}

function shaper_cmd {
    if [ "$1" = "stop" ]; then
        if check_interfaces_up "$LAN"; then
            tc qdisc del dev $LAN root 2> /dev/null
        fi
        if check_interfaces_up "$WAN"; then
            tc qdisc del dev $WAN root 2> /dev/null
        fi
 
    elif [ "$1" = "start" ]; then
        shaper_cmd stop
        if ! check_interfaces_up "$WAN" "$LAN"; then
            Log "error" "Interface check failed: skipping traffic shaping configuration."
            return 1
        fi
        delimiter=$IFS
        while IFS='=' read arg1 arg2; do
                case "$arg1" in
                LAN_INTERFACE_SPEED_LIMIT)        LAN_INTERFACE_SPEED_LIMIT=$arg2 ;;
                ISP_RX_LIMIT)                     ISP_RX_LIMIT=$arg2 ;;
                ISP_TX_LIMIT)                     ISP_TX_LIMIT=$arg2 ;;
                LAN_UNCLASSIFIED_RATE_LIMIT)      LAN_UNCLASSIFIED_RATE_LIMIT=$arg2 ;;
                LAN_UNCLASSIFIED_CEIL_LIMIT)      LAN_UNCLASSIFIED_CEIL_LIMIT=$arg2 ;;
                WAN_UNCLASSIFIED_RATE_LIMIT)      WAN_UNCLASSIFIED_RATE_LIMIT=$arg2 ;;
                WAN_UNCLASSIFIED_CEIL_LIMIT)      WAN_UNCLASSIFIED_CEIL_LIMIT=$arg2 ;;
                GW_TO_LAN_RATE_LIMIT)             GW_TO_LAN_RATE_LIMIT=$arg2 ;;
                GW_TO_LAN_CEIL_LIMIT)             GW_TO_LAN_CEIL_LIMIT=$arg2 ;;
                GW_TO_WAN_RATE_LIMIT)             GW_TO_WAN_RATE_LIMIT=$arg2 ;;
                GW_TO_WAN_CEIL_LIMIT)             GW_TO_WAN_CEIL_LIMIT=$arg2 ;;
                GW_TO_LAN_PRIORITY)               GW_TO_LAN_PRIORITY=$arg2 ;;
                GW_TO_WAN_PRIORITY)               GW_TO_WAN_PRIORITY=$arg2 ;;
                LAN_UNCLASSIFIED_PRIORITY)        LAN_UNCLASSIFIED_PRIORITY=$arg2 ;;
                WAN_UNCLASSIFIED_PRIORITY)        WAN_UNCLASSIFIED_PRIORITY=$arg2 ;;
                LAN_HOSTS_PRIORITY)               LAN_HOSTS_PRIORITY=$arg2 ;;
                WAN_HOSTS_PRIORITY)               WAN_HOSTS_PRIORITY=$arg2 ;;
                esac
        done < <(grep -v \# "$confdir/$shaper_file")
        IFS=$delimiter

        : "${LAN_INTERFACE_SPEED_LIMIT:=$DEFAULT_LAN_INTERFACE_SPEED_LIMIT}"
        : "${ISP_RX_LIMIT:=$DEFAULT_ISP_RX_LIMIT}"
        : "${ISP_TX_LIMIT:=$DEFAULT_ISP_TX_LIMIT}"
        : "${LAN_UNCLASSIFIED_RATE_LIMIT:=$DEFAULT_LAN_UNCLASSIFIED_RATE_LIMIT}"
        : "${LAN_UNCLASSIFIED_CEIL_LIMIT:=$DEFAULT_LAN_UNCLASSIFIED_CEIL_LIMIT}"
        : "${WAN_UNCLASSIFIED_RATE_LIMIT:=$DEFAULT_WAN_UNCLASSIFIED_RATE_LIMIT}"
        : "${WAN_UNCLASSIFIED_CEIL_LIMIT:=$DEFAULT_WAN_UNCLASSIFIED_CEIL_LIMIT}"
        : "${GW_TO_LAN_RATE_LIMIT:=$DEFAULT_GW_TO_LAN_RATE_LIMIT}"
        : "${GW_TO_LAN_CEIL_LIMIT:=$DEFAULT_GW_TO_LAN_CEIL_LIMIT}"
        : "${GW_TO_WAN_RATE_LIMIT:=$DEFAULT_GW_TO_WAN_RATE_LIMIT}"
        : "${GW_TO_WAN_CEIL_LIMIT:=$DEFAULT_GW_TO_WAN_CEIL_LIMIT}"
        : "${GW_TO_LAN_PRIORITY:=$DEFAULT_GW_TO_LAN_PRIORITY}"
        : "${GW_TO_WAN_PRIORITY:=$DEFAULT_GW_TO_WAN_PRIORITY}"
        : "${LAN_UNCLASSIFIED_PRIORITY:=$DEFAULT_LAN_UNCLASSIFIED_PRIORITY}"
        : "${WAN_UNCLASSIFIED_PRIORITY:=$DEFAULT_WAN_UNCLASSIFIED_PRIORITY}"
        : "${LAN_HOSTS_PRIORITY:=$DEFAULT_LAN_HOSTS_PRIORITY}"
        : "${WAN_HOSTS_PRIORITY:=$DEFAULT_WAN_HOSTS_PRIORITY}"
        if [ -z "$BURST" ]; then
            BURST=""
        else
            BURST="burst $BURST"
        fi

        #To WAN
        # Set limit for all traffic from WAN to Internet
        tc qdisc add dev $WAN root handle 2:0 htb default 3 r2q 1
        tc class add dev $WAN parent 2:0 classid 2:1 htb rate $ISP_TX_LIMIT ceil $ISP_TX_LIMIT burst 2000000 quantum 1514

        #Set limit for traffic from GATEWAY to WAN
        tc class add dev $WAN parent 2:1 classid 2:4 htb rate $GW_TO_WAN_RATE_LIMIT ceil $GW_TO_WAN_CEIL_LIMIT $BURST prio $GW_TO_WAN_PRIORITY quantum 1514
        tc qdisc add dev $WAN parent 2:4 fq_codel memory_limit 32Mb

        #To LAN
        # Set global limit for LAN interface
        tc qdisc add dev $LAN root handle 1:0 htb default 3 r2q 1
        tc class add dev $LAN parent 1:0 classid 1:1 htb rate $LAN_INTERFACE_SPEED_LIMIT ceil $LAN_INTERFACE_SPEED_LIMIT burst 1250000 quantum 1514

        # Set limit for all traffic from Internet to LAN
        tc class add dev $LAN parent 1:1 classid 1:2 htb rate 950000kbit ceil 950000kbit burst 1187500 quantum 1514

        #Set limit for traffic from GATEWAY to LAN
        tc class add dev $LAN parent 1:1 classid 1:4 htb rate $GW_TO_LAN_RATE_LIMIT ceil $GW_TO_LAN_CEIL_LIMIT $BURST prio $GW_TO_LAN_PRIORITY quantum 1514
        tc qdisc add dev $LAN parent 1:4 fq_codel memory_limit 32Mb

        #To and from CUSTOMERS
        #Set limit for customers host

        network_list=`awk '/filter / {split($2, ip, "."); print ip[1]"."ip[2]"."ip[3]}' "$confdir/$shaper_file" | sort -u`

        h=99
        while read arg1 arg2 arg3 arg4; do
            if [ "$arg1" = "customer" ]; then
                let h=$h+1
            elif [ "$arg1" = "class_up" ]; then
                rate=$(echo ${arg2/kbit/})
                rate=$((rate * 1000))
                CUSTOMER_UP_BURST=$(echo "$rate * 0.0125" | bc -l)
                ceil=$(echo ${arg3/kbit/})
                ceil=$((ceil * 1000))
                CUSTOMER_UP_CBURST=$(echo "$ceil * 0.0125" | bc -l)
                if ! check_interfaces_up "$WAN"; then
                    Log "error" "Interface $WAN check failed: skipping traffic shaping configuration."
                    return 1
                fi
                tc class add dev $WAN parent 2:1 classid 2:$h htb rate $arg2 ceil $arg3 burst ${CUSTOMER_UP_BURST}b cburst ${CUSTOMER_UP_CBURST}b prio $WAN_HOSTS_PRIORITY quantum 1514
                tc qdisc add dev $WAN parent 2:$h fq_codel memory_limit 4Mb

            elif [ "$arg1" = "class_down" ]; then
                rate=$(echo ${arg2/kbit/})
                rate=$((rate * 1000))
                CUSTOMER_DOWN_BURST=$(echo "$rate * 0.0125 " | bc -l)
                ceil=$(echo ${arg3/kbit/})
                ceil=$((ceil * 1000))
                CUSTOMER_DOWN_CBURST=$(echo "$ceil * 0.0125" | bc -l)
                if ! check_interfaces_up "$LAN"; then
            	    Log "error" "Interface $LAN check failed: skipping traffic shaping configuration."
                    return 1
            	fi
                tc class add dev $LAN parent 1:2 classid 1:$h htb rate $arg2 ceil $arg3 burst ${CUSTOMER_DOWN_BURST}b cburst ${CUSTOMER_DOWN_CBURST}b prio $LAN_HOSTS_PRIORITY quantum 1514
                tc qdisc add dev $LAN parent 1:$h fq_codel memory_limit 4Mb

            fi
        done < <(grep -v \# $confdir/$shaper_file)


        # Set default limit for traffic from WAN to Internet
        tc class add dev $WAN parent 2:1 classid 2:3 htb rate $WAN_UNCLASSIFIED_RATE_LIMIT ceil $WAN_UNCLASSIFIED_CEIL_LIMIT prio $WAN_UNCLASSIFIED_PRIORITY quantum 1514
        tc qdisc add dev $WAN parent 2:3 fq_codel memory_limit 1Mb

        #Set default limit for traffic from Internet to LAN
        tc class add dev $LAN parent 1:1 classid 1:3 htb rate $LAN_UNCLASSIFIED_RATE_LIMIT ceil $LAN_UNCLASSIFIED_CEIL_LIMIT prio $LAN_UNCLASSIFIED_PRIORITY quantum 1514
        tc qdisc add dev $LAN parent 1:3 fq_codel memory_limit 1Mb

    elif [ "$1" = "status" ]; then
        echo
        echo "$LAN interface"
        echo "----------------"
        for TC_OPTIONS in qdisc class filter; do
            if [ ! -z "$LAN" ]; then
                echo
                echo "$TC_OPTIONS"
                echo "------"
                tc $TC_OPTIONS show dev $LAN
            fi
        done

        echo
        echo "$WAN interface"
        echo "----------------"
        for TC_OPTIONS in qdisc class filter; do
            if [ ! -z "$WAN" ]; then
                echo
                echo "$TC_OPTIONS"
                echo "------"
                tc $TC_OPTIONS show dev $WAN
            fi
        done
    elif [ "$1" = "stats" ]; then
        python3 ip_accounting.py
    fi

}

function shaper_reload {
	compare_files_sha1 "$confdir/$shaper_file" "$oldconfdir/$shaper_file"
	case $? in
		0)
                  Log info "The Shaper configuration is identical, a reload is not needed" 
                  ;;
		1)
                   Log info "The Shaper has a new configuration, reloading Shaper"; 
                   shaper_cmd stop
                   shaper_cmd start
                   accounting stop
                   accounting start
                   ;;
		2)
                   Log error "The Shaper files not exist"
                   ;;
	esac
}

function dhcpd_reload {
    compare_files_sha1 "$confdir"/"dhcpd.conf" "$oldconfdir"/"dhcpd.conf"
	case $? in
		0) Log info "The DHCP config file is identical, a reload is not needed" ;;
		1) Log info "The dhcpd.conf file has a new configuration, reloading the DHCP server"; dhcp_server_cmd restart ;;
		2) Log error "The DHCP config files not exist" ;;
	esac
}

function gw_cron {
    if [ "$1" = "start" ]; then
        echo "# Run the gw.sh cron jobs
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=""
* * * * * root $scriptsdir/gw.sh reload_new_config  > /dev/null 2>&1
00 22 * * * root $scriptsdir/gw.sh shaper_reload  > /dev/null 2>&1
00 10 * * * root $scriptsdir/gw.sh shaper_reload  > /dev/null 2>&1
" > /etc/cron.d/gw_sh
        Log info "Enabling cron for gw.sh"

    elif [ "$1" = "stop" ]; then
        if [ -f /etc/cron.d/gw_sh ]; then
            rm /etc/cron.d/gw_sh
        fi
        Log info "Disabling cron for gw.sh"
    fi
}

function accounting {
    case "$1" in
        start)
            nft flush table ip mangle 2>/dev/null
            nft delete table ip mangle 2>/dev/null
            nft add table ip mangle

            nft add chain ip mangle FORWARD { type filter hook forward priority -150 \; }

            # Create per-subnet chains and jump rules
            network_list=$(awk '/filter / {split($2, ip, "."); print ip[1]"."ip[2]"."ip[3]}' "$confdir/$shaper_file" | sort -u)

            for net in $network_list; do
                chain_in="COUNTERSIN_${net//./_}"
                chain_out="COUNTERSOUT_${net//./_}"

                nft add chain ip mangle $chain_in
                nft add chain ip mangle $chain_out

                nft add rule ip mangle FORWARD iifname "$WAN" ip daddr "$net.0/24" jump $chain_in
                nft add rule ip mangle FORWARD oifname "$WAN" ip saddr "$net.0/24" jump $chain_out
            done

            # Populate per-subnet chains with host-specific rules
            h=99
            while read arg1 arg2 arg3 arg4; do
                if [ "$arg1" = "filter" ]; then
                    IFS='.' read -r o1 o2 o3 o4 <<< "$arg2"
                    chain_in="COUNTERSIN_${o1}_${o2}_${o3}"
                    chain_out="COUNTERSOUT_${o1}_${o2}_${o3}"

                    nft add rule ip mangle $chain_out ip saddr "$arg2" meta mark set $((0x200 + h)) counter
                    nft add rule ip mangle $chain_in ip daddr "$arg2" meta mark set $((0x100 + h)) counter
                fi
            done < "$confdir/$shaper_file"

            echo "$(date) - nftables accounting chains and rules loaded"
            ;;
        stop)
            nft flush table ip mangle 2>/dev/null
            nft delete table ip mangle 2>/dev/null
            echo "$(date) - nftables accounting rules removed"
            ;;
        *)
            echo "Usage: accounting {start|stop}"
            return 1
            ;;
    esac
}
