cat <<EOF > kkantor_audit.sh
#!/usr/bin/bash

vers=$(uname -v)
platform="joyent_20181220T002335Z"

if [ "$vers" = "$platform" ];
then
        echo "N/A"
else
        patched=$(mdb -ke 'metaslab_debug_unload::print')
        if [ "" = "0" ];
        then
                vms=$(vmadm list -Ho alias | tr '\n' ' ')
                echo "platform: $vers"
                echo "vms: $vms"
        else
                echo "patched"
        fi
fi
