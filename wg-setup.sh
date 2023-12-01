#!/bin/bash

IPV4_FORWARD=0
ADD_PEER=0
GENKEY=0
AUTOCONNECT="yes"

usage() {
   echo "wg-srv.sh [OPTION] [VALUE]"
   echo " -a|--add-peer       add a peer to the server; Required: -c and -pk" 
   echo "-ac|--autoconnect    automatically start the connection at boot [yes|no]; Default: yes"
   echo "    --allowed-ip     sets tunnel IP addresses of the clients allowed to send data to the server"
   echo "                     or tunnel IP addresses of the servers to allowed to communicate with client"
   echo "                     use -r|--route_all to route all traffic through the tunnel "
   echo " -c|--conn-name      network manager connection name; Default: wg0-[client|server]"
   echo " -e|--endpoint       sets the hostname or IP address of the server"
   echo " -f|--ipv4-forward   sets ipv4 forwarding for vpn gateway functionality; Masquerading will be enabled"
   echo " -g|--gateway        gateway IP; use server tunnel ip as gateway"
   echo "    --genkey         generate public and private keys only"
   echo "-ip|--tunnel-ip      client or server tunnel ip in CIDR notation"
   echo " -p|--port           port the server should listen on; Default: 51820"
   echo "-pk|--peer-pubkey    peer public key"
   echo " -r|--route-all      route all traffic through tunnel; Only valid for client"
   echo " -t|--type           type of install; Options: [client|server]"
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
	  -ac|--autoconnect)
	     AUTOCONNECT=$2
	     shift 2
	     ;;
	  --allowed-ip)
	     ALLOWED_IP=$2
	     shift 2
	     ;;
	  -c|--conn-name)
	     CONN_NAME=$2
	     shift 2
	     ;;
	  -e|--endpoint)
	     ENDPOINT=$2
	     shift 2
	     ;;
	  -f|--ipv4-forward)
	     IPV4_FORWARD=1
	     shift 1
	     ;;
	  -g|--gateway)
	     GATEWAY=$2
	     shift 2
	     ;;
	  --genkey)
	     GENKEY=1
	     shift 1
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
	  -r|--route-all)
	     ROUTE_ALL="0.0.0.0/0;"
	     shift 1
	     ;;
	  -t|--type)
	     TYPE=$2
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

validate_args() {
   TYPE=$(echo $TYPE | tr '[:upper:]' '[:lower:]')
   VIRT_IFNAME=$(echo $VIRT_IFNAME | tr '[:upper:]' '[:lower:]')
  
   case $ADD_PEER in
      0)
	 if [ $GENKEY -eq 0 ]; then
            [ ! $TUNNEL_IP ] && abnormal_exit "missing [-ip|--tunnel-ip] argument" usage
            [ ! $TYPE ] && abnormal_exit "missing [-t|--type] argument" usage
            [ ! $VIRT_IFNAME ] && VIRT_IFNAME="wg0"
            [ ! $PORT ] && PORT=51820
            [ ! $CONN_NAME ] && CONN_NAME=$VIRT_IFNAME"-"$TYPE
	 fi
	 ;;
      1)
         [ ! $ALLOWED_IP ] && abnormal_exit "missing required argument --allowed-ip" usage
         [ ! $PEER_PUBKEY ] && abnormal_exit "missing required argument -pk|--peer-pubkey" usage
         [ ! $TYPE ] && abnormal_exit "missing required argument [ -t|--type]" usage
	 ;;
   esac

   if [[ $ROUTE_ALL ]] && [[ $ALLOWED_IP ]]; then
      abnormal_exit "--route-all and --allowed-ip cannot be used together" usage
   fi 

   if [ "$TYPE" = "client" ]; then
      [ -n $ENDPOINT ] && abnormal_exit "missing required argument -e|--endpoint" usage
   fi 
}

check_conn() {
   printf "Checking for existing connections ..."
   
   local con=$(nmcli connection show | grep -o $CONN_NAME)
   [[ $con ]] && abnormal_exit "A NetworkManager connection already exists by that name: $CONN_NAME"
   
   printf "Done\n"
}

install_pkg() {
   printf "Installing wireguard ...\n"
   dnf -y install wireguard-tools
}

genkeys() {
   [ $GENKEY -eq 1 ] && install_pkg

   local found=0

   if [ -f "/etc/wireguard/privatekey" ] || [ -f "/etc/wireguard/publickey" ]; then
      printf "Wireguard encryption keys were found. Overwrite? (y/N): "
      found=1
      local _answer
      read _answer
   fi

   if [[ $_answer = "y" ]] || [[ $found -eq 0 ]]; then
      printf "Generating keys ..."
      umask 077; wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
      printf "Done\n"
   fi

   if [ $GENKEY -eq 1 ]; then
      get_keys
      echo "Public Key: $PUBLIC_KEY"
      exit 0
   fi
}

get_keys() {
   [ ! -f "/etc/wireguard/privatekey" ] && abnormal_exit "private key not found; use --genkey"
   [ ! -f "/etc/wireguard/publickey" ] && abnormal_exit "public key not found; use --genkey"

   PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
   PUBLIC_KEY=$(cat /etc/wireguard/publickey)
}

create_connection() {
   printf "Adding NetworkManager WireGuard connection profile ...\n"
   nmcli connection add type wireguard con-name $CONN_NAME ifname $VIRT_IFNAME autoconnect no

   # "Set the tunnel IPv4 address and subnet mask ..."
   nmcli connection modify $CONN_NAME ipv4.method manual ipv4.addresses $TUNNEL_IP

   # If Gateway argument was provided, set the gateway ip
   [[ $GATEWAY ]] &&  nmcli connection modify $CONN_NAME ipv4.gateway $GATEWAY

   # "Adding private key to the connection profile ..."
   nmcli connection modify $CONN_NAME wireguard.private-key "$PRIVATE_KEY"

   # "Setting port for incoming WireGuard connections ..."
   [ $TYPE = "server" ] && nmcli connection modify $CONN_NAME wireguard.listen-port $PORT

    printf "Adding peer configuration ..."
    [ $PEER_PUBKEY ] && add_peer
    [ ! $PEER_PUBKEY ] && printf "No peer key Skipping\n"

    # "Reloading the connection profile ..."
    nmcli connection load /etc/NetworkManager/system-connections/$CONN_NAME.nmconnection

    printf "Configuring connection autoconnect ..."
    nmcli connection modify $CONN_NAME autoconnect $AUTOCONNECT
    printf "Done\n"
   
    printf "Reactivating the connection ...\n"
    nmcli connection up $CONN_NAME
}

add_peer() {
   local config="/etc/NetworkManager/system-connections/$CONN_NAME.nmconnection"

   case $TYPE in
      "client")
         echo "[wireguard-peer.$PEER_PUBKEY]" >> $config
         echo "endpoint=$ENDPOINT:$PORT" >> $config
         [ -n $ROUTE_ALL ] && echo "allowed-ips=$ROUTE_ALL" >> $config
         [ -n $ALLOWED_IP ] && echo "allowed-ips=$ALLOWED_IP" >> $config
         echo "persistent-keepalive=20" >> $config
	 ;;
      "server")
         echo "[wireguard-peer.$PEER_PUBKEY]" >> $config
         echo "allowed-ips=$ALLOWED_IP;" >> $config
         ;;
      *)
         abnormal_exit "Type not found in add_peer"
   esac

   if [ $ADD_PEER -eq 1 ]; then
      nmcli connection load /etc/NetworkManager/system-connections/$CONN_NAME.nmconnection
      nmcli connection up $CONN_NAME
      exit 0
   fi

   printf "Done\n"
}

ip_forward() {
   printf "Enabling ipv4 forwarding ..."
   sysctl -w net.ipv4.ip_forward=1
   sysctl -p
   printf "Done\n"
}

get_network() {
   local _subnet=$(echo $TUNNEL_IP | grep -oP "/\d{1,2}")
   local _net=""
   local _source_addr=""

   case $_subnet in
      "/8")
	 _net=$(echo "$TUNNEL_IP" | grep -oP "^\d{1,3}")
         _net+=".0.0.0/8"
	 ;;
      "/16")
	 _net=$(echo "$TUNNEL_IP" | grep -oP "^\d{1,3}\.\d{1,3}")
         _net+=".0.0/16"
	 ;;
      "/24")
         _net=$(echo "$TUNNEL_IP" | grep -oP "^\d{1,3}\.\d{1,3}\.\d{1,3}")
	 _net+=".0/24"
	 ;;
      *)
	echo "subnet not found"
	;;
   esac

   local _result=$1
   eval $_result="'$_net'"
}

add_firewall_rules() {
   local _src_addr
   get_network _src_addr

   firewall-cmd --permanent --add-port="$PORT/udp" --zone=public
   firewall-cmd --permanent --zone=internal --add-interface=$VIRT_IFNAME

   [ $IPV4_FORWARD -eq 1 ] &&
         firewall-cmd --zone=public --add-rich-rule="rule family=\"ipv4\" source address=\"$_src_addr\" masquerade" --permanent
      
   firewall-cmd --reload
}

main() {
   parse_args $@
   validate_args
   [ $ADD_PEER -eq 1 ] && add_peer
   [ $GENKEY -eq 1 ] && genkeys 
   check_conn
   install_pkg
   get_keys
   create_connection
   add_firewall_rules

   wg show wg0
}

main $@
