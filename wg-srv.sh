#!/bin/bash

ADD_PEER=0
CONN_NAME="wg0-server"
TUNNEL_IP="10.8.0.1/24"
VIRT_IFNAME="wg0"
PORT=51820

usage() {
   echo "wg-srv.sh [OPTION] [VALUE]"
   echo " -a|--add-peer       add a peer to the server; Required: -c and -pk" 
   echo " -c|--conn-name      network manager connection name; Default: wg0-server"
   echo "-ip|--tunnel-ip      server tunnel ip in CIDR notation; Default: 10.8.0.1/24"
   echo " -p|--port           port the server should listen on; Default: 51820"
   echo "-pk|--peer-pubkey    peer public key"
   echo " -v|--virt-ifname    virtual interface name; Default: wg0"
   echo " -h|--help           display help information"

   exit 0
}

abnormal_exit() {
   echo "Error: $1"
   $2
   exit 1
}

parse_args() {
   while (($#))
   do
      case $1 in
	  -a|--add-peer)
	     ADD_PEER=1
	     shift 1
	     ;;
	  -c|--conn-name)
	     CONN_NAME=$2
	     shift 2
	     ;;
         -ip|--tunnel-ip)
	    TUNNEL_IP=$2
	    shift 2
	    ;;
	  -p|--port)
	    PORT=$2
	    shift 2
	    ;;
	 -pk|--peer-pubkey)
	    PEER_PUBKEY=$2
	    shift 2
	    ;;
	  -v|--virt-ifname)
	    VIRT_IFNAME=$2
	    shift 2
	    ;;
	  -h|--help)
            usage
	    ;;
      esac
   done
}

#validate_args() {
#   [ -n $PEER_PUBKEY ] && abnormal_exit "missing required argument -pk|--peer-pubkey" usage
#}

install_pkg() {
   printf "Installing wireguard ...\n"
   dnf -y install wireguard-tools
}

genkeys() {
   printf "Generating keys ..."
   
   umask 077; wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
   PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
   
   printf "Done\n"
}

create_connection() {
    printf "Adding NetworkManager WireGuard connection profile ..."
    nmcli connection add type wireguard con-name $CONN_NAME ifname $VIRT_IFNAME autoconnect no
    printf "Done\n"

    printf "Set the tunnel IPv4 address and subnet mask ..."
    nmcli connection modify $CONN_NAME ipv4.method manual ipv4.addresses $TUNNEL_IP
    printf "Done\n"

    printf "Adding private key to the connection profile ..."
    nmcli connection modify $CONN_NAME wireguard.private-key "$PRIVATE_KEY"
    printf "Done\n"

    printf "Setting port for incoming WireGuard connections ..."
    nmcli connection modify $CONN_NAME wireguard.listen-port $PORT
    printf "Done\n"

    printf "Adding peer configuration ..."
    [ $PEER_PUBKEY ] && add_peer
    [ -n $PEER_PUBKEY ] && printf "No peer key Skipping\n"

    printf "Reloading the connection profile ..."
    nmcli connection load /etc/NetworkManager/system-connections/$CONN_NAME.nmconnection
    printf "Done\n"

    printf "Configuring the connection to start automatically ..."
    nmcli connection modify $CONN_NAME autoconnect yes
    printf "Done\n"
   
    printf "Reactivating the connection ..."
    nmcli connection up $CONN_NAME
    printf "Done\n"
}

add_peer() {
   local tunnel_subnet=$(echo $TUNNEL_IP | grep -oP "^\d{1,3}\.\d{1,3}\.\d{1,3}\.")
   local subnet_length=${#tunnel_subnet}
   local host=${TUNNEL_IP:subnet_length:5}

   if [ $host -le 253 ]; then
      local peer_ip="$tunnel_subnet$(expr $host + 1)"
   else
      abnormal_exit "host address out of range"
   fi

cat << EOF >> /etc/NetworkManager/system-connections/$CONN_NAME.nmconnection
[wireguard-peer.$PEER_PUBKEY]
allowed-ips=$peer_ip;
EOF

   printf "Done\n"
}

main() {
   parse_args $@

   if [ $ADD_PEER -eq 1 ]; then
      add_peer
      exit 0
   fi

   install_pkg
   genkeys
   create_connection
}

main $@
