# IPMI abstraction because I can't remember IPMI commands.
function server() {
    cmd="ipmitool -I lanplus -H FILL_IN_IP -U FILL_IN_USERNAME -P FILL_IN_PASSWORD"
    case "$1" in
        power)
            subcmd="chassis power"
            case "$2" in
                on | off | status | cycle)
                    eval $cmd $subcmd $2
                    ;;
                *)
                    echo "server power [on|off|status] - toggle mcenroe power"
                    ;;
            esac
            ;;
        connect)
            subcmd="sol activate"
            eval $cmd $subcmd 
            ;;
        ssh)
            ping_wait
            sleep 5
            subcmd="ssh mcenroe"
            eval $subcmd
            ;;
        status)
            subcmd="sensor"
            eval $cmd $subcmd
            server power status
            ;;
        *)
            echo "server [power|connect|ssh|status] - mcenroe management"
            ;;
    esac
}

# Hang until the host responds to .
function ping_wait() {
    echo 'Waiting until server is up...'
    ping -t 1 -c 1 -q mcenroe &> /dev/null
    retval=$?
    while [[ $retval -ne 0 ]]; do
        sleep 1
        ping -t 1 -c 1 -q mcenroe &> /dev/null
        retval=$?
    done
}
