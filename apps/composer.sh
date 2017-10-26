#!/bin/bash
set -ev

# Docker stop function
function stop()
{
P1=$(docker ps -q)
if [ "${P1}" != "" ]; then
  echo "Killing all running containers"  &2> /dev/null
  docker kill ${P1}
fi

P2=$(docker ps -aq)
if [ "${P2}" != "" ]; then
  echo "Removing all containers"  &2> /dev/null
  docker rm ${P2} -f
fi
}

if [ "$1" == "stop" ]; then
 echo "Stopping all Docker containers" >&2
 stop
 exit 0
fi

# Get the current directory.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get the full path to this script.
SOURCE="${DIR}/composer.sh"

# Create a work directory for extracting files into.
WORKDIR="$(pwd)/composer-data-latest"
rm -rf "${WORKDIR}" && mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Find the PAYLOAD: marker in this script.
PAYLOAD_LINE=$(grep -a -n '^PAYLOAD:$' "${SOURCE}" | cut -d ':' -f 1)
echo PAYLOAD_LINE=${PAYLOAD_LINE}

# Find and extract the payload in this script.
PAYLOAD_START=$((PAYLOAD_LINE + 1))
echo PAYLOAD_START=${PAYLOAD_START}
tail -n +${PAYLOAD_START} "${SOURCE}" | tar -xzf -

# Ensure sensible permissions on the extracted files.
find . -type d | xargs chmod a+rx
find . -type f | xargs chmod a+r

# Pull the latest versions of all the Docker images.
docker pull hyperledger/composer-playground:latest
docker pull hyperledger/composer-cli:latest
docker pull hyperledger/composer-rest-server:latest
docker pull hyperledger/vehicle-lifecycle-vda:latest
docker pull hyperledger/vehicle-lifecycle-manufacturing:latest
docker pull hyperledger/vehicle-lifecycle-car-builder:latest
docker pull nodered/node-red-docker

# stop all the docker containers
stop

# run the fabric-dev-scripts to get a running fabric
./fabric-dev-servers/downloadFabric.sh
./fabric-dev-servers/startFabric.sh

# Create the environment variables and file with the connection profile in.
read -d '' COMPOSER_CONNECTION_PROFILE << EOF || true
{
    "name": "hlfv1",
    "description": "Hyperledger Fabric v1.0",
    "type": "hlfv1",
    "keyValStore": "/home/composer/.composer-credentials",
    "timeout": 300,
    "orderers": [
        {
            "url": "grpc://orderer.example.com:7050"
        }
    ],
    "channel": "composerchannel",
    "mspID": "Org1MSP",
    "ca": {"url": "http://ca.org1.example.com:7054", "name": "ca.org1.example.com"},
    "peers": [
        {
            "requestURL": "grpc://peer0.org1.example.com:7051",
            "eventURL": "grpc://peer0.org1.example.com:7053"
        }
    ]
}
EOF
read -d '' COMPOSER_CONFIG << EOF || true
{
    "cards": [{
        "metadata": {
            "version": 1,
            "userName": "admin",
            "enrollmentSecret": "adminpw",
            "businessNetwork": "vehicle-lifecycle-network"
        },
        "connectionProfile": ${COMPOSER_CONNECTION_PROFILE},
        "credentials": null
    }]
}
EOF
mkdir -p .composer-connection-profiles/hlfv1
echo ${COMPOSER_CONNECTION_PROFILE} > .composer-connection-profiles/hlfv1/connection.json

# Copy the credentials in.
cp -r fabric-dev-servers/fabric-scripts/hlfv1/composer/creds .composer-credentials

# Start the playground.
docker run \
  -d \
  --network composer_default \
  --name composer \
  -v $(pwd)/.composer-connection-profiles:/home/composer/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  -e COMPOSER_CONFIG="${COMPOSER_CONFIG}" \
  -p 8080:8080 \
  hyperledger/composer-playground:latest

# Doctor the permissions on the files so Docker can pointlessly overwrite them.
chmod a+rwx .composer-connection-profiles .composer-connection-profiles/hlfv1 .composer-credentials
chmod a+rw .composer-connection-profiles/hlfv1/connection.json
chmod a+rw .composer-credentials/*

# Deploy the business network archive.
docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/vehicle-lifecycle-network.bna:/home/composer/vehicle-lifecycle-network.bna \
  -v $(pwd)/.composer-connection-profiles:/home/composer/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  hyperledger/composer-cli:latest \
  composer network deploy -p hlfv1 -a vehicle-lifecycle-network.bna -i PeerAdmin -s randomString -A admin -S

# Submit the setup transaction.
docker run \
  --rm \
  --network composer_default \
  -v $(pwd)/.composer-connection-profiles:/home/composer/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  hyperledger/composer-cli:latest \
  composer transaction submit -p hlfv1 -n vehicle-lifecycle-network -i admin -s adminpw -d '{"$class": "org.acme.vehicle.lifecycle.SetupDemo"}'

# correct the admin credential permissions
docker run \
  --rm \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  hyperledger/composer-cli:latest \
  find /home/composer/.composer-credentials -name "*" -exec chmod 777 {} \;

# Start the REST server.
docker run \
  -d \
  --network composer_default \
  --name rest \
  -v $(pwd)/.composer-connection-profiles:/home/composer/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  -e COMPOSER_CONNECTION_PROFILE=hlfv1 \
  -e COMPOSER_BUSINESS_NETWORK=vehicle-lifecycle-network \
  -e COMPOSER_ENROLLMENT_ID=admin \
  -e COMPOSER_ENROLLMENT_SECRET=adminpw \
  -e COMPOSER_NAMESPACES=required \
  -p 3000:3000 \
  hyperledger/composer-rest-server:latest

# Wait for the REST server to start and initialize.
sleep 10

# Start Node-RED.
docker run \
  -d \
  --network composer_default \
  --name node-red \
  -v $(pwd)/.composer-connection-profiles:/usr/src/node-red/.composer-connection-profiles \
  -v $(pwd)/.composer-credentials:/usr/src/node-red/.composer-credentials \
  -v $(pwd)/.composer-credentials:/home/composer/.composer-credentials \
  -e COMPOSER_BASE_URL=http://rest:3000 \
  -v $(pwd)/flows.json:/data/flows.json \
  -p 1880:1880 \
  nodered/node-red-docker

# Install custom nodes
docker exec \
  -e NPM_CONFIG_LOGLEVEL=warn \
  node-red \
  bash -c "cd /data && npm install node-red-contrib-composer@latest"
docker restart node-red

# Wait for Node-RED to start and initialize.
sleep 10

# Start the VDA application.
docker run \
-d \
--network composer_default \
--name vda \
-e COMPOSER_BASE_URL=http://rest:3000 \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 6001:6001 \
hyperledger/vehicle-lifecycle-vda:latest

# Start the manufacturing application.
docker run \
-d \
--network composer_default \
--name manufacturing \
-e COMPOSER_BASE_URL=http://rest:3000 \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 6002:6001 \
hyperledger/vehicle-lifecycle-manufacturing:latest

# Start the car-builder application.
docker run \
-d \
--network composer_default \
--name car-builder \
-e NODE_RED_BASE_URL=ws://node-red:1880 \
-p 8100:8100 \
hyperledger/vehicle-lifecycle-car-builder:latest

# Wait for the applications to start and initialize.
sleep 10

# Open the playground in a web browser.
URLS="http://localhost:8100 http://localhost:6002 http://localhost:6001 http://localhost:8080 http://localhost:3000/explorer/ http://localhost:1880"
case "$(uname)" in
"Darwin") open ${URLS}
          ;;
"Linux")  if [ -n "$BROWSER" ] ; then
	       	        $BROWSER http://localhost:8100 http://localhost:6002 http://localhost:6001 http://localhost:8080 http://localhost:3000/explorer/ http://localhost:1880
	        elif    which x-www-browser > /dev/null ; then
                  nohup x-www-browser ${URLS} < /dev/null > /dev/null 2>&1 &
          elif    which xdg-open > /dev/null ; then
                  for URL in ${URLS} ; do
                          xdg-open ${URL}
	                done
          elif  	which gnome-open > /dev/null ; then
	                gnome-open http://localhost:8100 http://localhost:6002 http://localhost:6001 http://localhost:8080 http://localhost:3000/explorer/ http://localhost:1880
	        else
    	            echo "Could not detect web browser to use - please launch Composer Playground URL using your chosen browser ie: <browser executable name> http://localhost:8080 or set your BROWSER variable to the browser launcher in your PATH"
	        fi
          ;;
*)        echo "Playground not launched - this OS is currently not supported "
          ;;
esac

# Exit; this is required as the payload immediately follows.
exit 0

PAYLOAD:
� ނ�Y �Y�+Y��z������Y�ݣ�G��*�{U���|�%u�.�\�[23�J�b#�`�$�,=�l@�5��1���C �����,��Gl���C��lK�c�����d׋Sx���/��{�D�)�*�P��,��/M6���4��� �&�'_��g���U��ٿ���a�=�8C�8C���I{�bT��06L~��O$Q�F�lU�}终�����y��ӗ�ӏ���	��� lȋ}�+�.]�j_ֺ�&�/����P7��������p2��~����L����s72]�@��� 0��1�c�$H!Ɇ8R�����.-�e��EYN��h"H�3͡�2�͆�H���<�u�7b�w[����e����G#���q�+��n�n^1�,m�n�N[���e8��cAU�h̠/)�!�K�a�?�9�֏�#��LdTɠ}����#Qn�f� �"�f��/x������4��Ԯ�h����� ���r_6�4���.ӊb�o��~��?d͐_�=Y�/29�n6I!���ܿ0�_���,���#Y�}!�V��� ��Ё.�x�b��`l,L����ŝ!��A10� ��X�b�z�Hfd�T68 �ߋk�b,�/���&�3wMYC�<��X�˟�����}~l�t�F�Z��2�3� 0�'� �:��-k������W�|�K2��[c��dل�>�tH$�]6j~'b���6����$'/|���\%[8�k�,�)z!Y��E�Mi��":����&�U;!�@��6v"�J�GK����^sv^�Jj������>pZL�p�y(���t�#����?X2�,�Q@�0���|��2VY�c�����cț�J�d^Tʼ�x+���W4P�9ˠ]z��u���^5�on4�8�_�������o��>��߻ �α�2H�k�8����S��[�bh�fϛX�%hg����;�h�G2j� �F����,|T�&�:�AÑ2�$N�j��<��(�Iv&t ��CYt$w� ��
���U�p�O	�d��n�M��n�2�	RN{:H
҉�a���06 �\�O�;0�%�|��1?$J?��������!�~	�*�����������Uv
|�����؝�ӛ/a%�a�v�Ցd�w�Ҋm�x��j�4�*/�n��P�����ɛc���!�Vf��#�(��nFVhF���$�N:����h�������ѭ�����3��et�%%��aV�V�����VXX�o�v��V{��bh��	B��X�2���o���(>w���N�S�Jˡ�h�U�Z��{�覈='� [�]e�r���L�9�a;fh�7q}1s���:T�9m1aY�=w�yOSAg;&`=��3A{<X���Z	S�Vz
�k�-�ŨX�0?�فg��_!��&��"�w Q�(���C�q{Io���`; � D2&U�5QF�@(p)\|V��7�P�rP��ǚ�kL��V3��f͈ꥲ��|H�t�w{��.s�6��tL�JT4� @L@�?FM^ 䭱l�b�z�|���W��(��t_uc�8�cn;͋-��G^[Ym
���P�-��j�������y�He9�=��
s
��셓�Os�)-��}�牶Vޒ�9v��]QU�&p.��	W�2-o��w,�P�;��Ɩ��?�%��gQ�E�D���2���+*,V�R�D�c'����t�/�T�H�P�lZ�3�����w�Dwaxc���*�0��@�k�I�N��#�V[^޶����`�0{ n_�7>0ua���u���_ ��t0E�J���2k?���"���Q���G���7�!����~��R�g� 8���m���\����VZ96�l�9O�fЪ�K�c~�[�6��ްRA"����/a�_�yF։�Āy��Z0L����i�
�����K6���dQp[s� 5���խ����� ��$�C�bhN!`�ɠ��Y�A�����Xo{�& ��o ���	ء�����������%��aXl�U�� ��hê�E�u���*`gd��82�dS�X5b�1.AJ��:`߀ �ɹ] e�b��o��I	K����:h"o˖JV���]Kl�,E����l��17`3%���փ5eE�0�'p�L��v`����fx-S�������_��+}
�躢�n�w��oj�-h�
���r���2����x�]8cXڵvS��m���^?}�Ҝ�z����noo7�+��_�^���`��������|�����Do�1���(�V	k��^؆,7�9Ј,{3J�0�L��D��	,b��-]�M�=���Q���W�<4!�
��Hh�3�] �8��g��x��	��Ԑ�Z:�Nc���ոc 2�b��48h�s2�4N�H�+PG��Ca�R��SK��:kqЂ�H�J�s��;�ɰ����/�y���`Ā���6�bcM��b�9,�]l��&�f�u��,r�ZG3�J��,V+�+���+��F�#_G�ОGh���e_\�eej��kZw�څ�f�s�� �0X�� ��0��~ٌ �H˂�Y��|?��Ȏ[��m��qne`z��<qAdm<@�UX�:ZfK����_�f��C�p�όp0/�:� #�e*&T�,z��ޘ��^�
�����}�IR-+�H�t�k�	ϭ�v(�&�ߗ�0&�#�[����K�jMύ��dY �,b$��"RP��,��FS�����X��=][3�=}�D�bYI�P�w��5��O�AY �50=�@رR�V;���`O��	-�Jq]���eW�[�m2K�2��f�]����߰��9�_��TuCX!~�GB�X*aQN��G��%IA��R�J����KrZ����wټ��������׾��	����}9,>ba��G2!h�>2��*f��8g�.) �0^�����dX�
Ͷ�d��O��t9���K����F�x��	���2��������.��	���幰�E�d;��_�[S�?��:��YkS)�v�p����BI2l.L}�u�+���`�����=u��I`�f]��`��\_�����5 ��?]R.��%�^��@ ��lb��RVm�f���u�4.(`�z��l�%�R�E�!��Dh5��<�>��������:�{R��b�b��$��+\���J����b�w`�ܝ'�Y:�L�H����1Y����҂���B�s�y[��#7��i��CsXƪ�^|m�y� ��7�
�֍;���g��dc���������R'�["��-{�=�Y/9�r��]�����*p��h�mZn9&g����x�����J��^*����6�(7{w��ׇ�^��r?`�a٠렽�}�Glڈ����6�
_���X���n��ES'J��1��p��R	�Հ` �ʞ���q
�%@on��4?���6����<��~��ސ&FL;b�wb���+[�2D��0Y���.��g�
�t�?��V��F^�t���n�V��.�-��$AQq|�}��U�[���^<a�ܫR1_h��W�ن�5��ҫ[��*�n�ɖ�\��6�}�ky"<ż:�
�L�f�\�^%_]K��-p��YH���u�c.SdK��gǜݩ�*�y�Me�[��r�Y�g�m*q�f��y×�n��"e�TzUl��J�S�2U ���6`u��K�����J�\=�U2���i�+7a�ƥ _���C��9�~Q:�Z���)��N�PѰ�.�,ok_��M������|i��)w�m.�/�r[���3U�k;I抑-��!)u�+���x�M�VV;�1 ���cU�4�X����$��ʴD�p�xړeį�/52`^���"l/;�ޚ�4�y�=�*�y�O=����O���<\_̱C]�gye����5��D��C�{2�p��1kA�k����A�܍1��d�U�&�`r0�c"p�f�_���>�I����n���	v�e����*4l�ŏf�P{�C�_�4R&rz�)xe ��
�WO�~i��?��P����e{��R7׋��w9�8�Zl\N��¶0��oC:�:S�	��i0r�#?��g]�������m���}Y�>J-MT>�ʲ���4p.G�#��%,�T�rP�1PO�y�����zii�wڜ��S�k{x�̪��Ѻ��C*�*l�Ñc��EB@u��	Zg�LN>����d�r���U�ʺ6�:{|l l}��_#���ǱA�-5q�&ޯ��	]�6��K/�2KW�c��
�j�T��R�?�M��Dܪ��?�����ݰ6���Aӏ%O�v���k�_;�������>y��y�SǸi�����Y�Ż�0,�q7mŒ쳻z}0��vR٠�1@{��D�H�Cq�~�x�ē[�[�W���3J7��hO�H��?jŭw䉪����o���x����='�o��(LDa�@a\c��3���� =?@�����׎�U����2��8�j��q�3֜�/�<ϖ??r�M��a�1z���e�S��V��]��9��)ڕ͜����_i�*�ȧ���So������ʺ�'���>{�?u���i��L}��}jw�g,bΆ���+�=A����8o.�����{�M�ێ��Y)s�W����2=�򲑐��;d��r�ѳ��y��Q�>Z$��#�C/h���:���dxf�	��XUg�1�Z��@�VV1P��l�x����E6�j��/Iv�d@x���gم��.��a`O�7^V���ݧ����}7P���0݋*�3��M:}�4�y(�i̻�����V��;Ӗ����Φ�wWɦ4+IoOpV�|�J~VR��P!�j�絖��__+=��Q�5���V��Bk,д]a�]I0j���~�>u] ���ŵ�d�}W頫3�o�`L��
O�K�Z�nsגj�ߟ��{2І�.�3��׍w�¼�@���BA��e,��׀�t5_qt�t�5
td fun3;~ב��� ��gע�r茰nDqO~0�}���׈m���:��`>
mM ��q\��k��6��LX0�m�Zϸ��4�,���t��5l�� �������ѧ��h`u���\���7�h��b���0���.o]x��O� ��M߇{ @ ��Ƨ�L�[nl���������˲*�Q@�/6/*_�_�"�"�f[�ll86z���iD�&���!�.�oW���^��z[��0z��ׯ�u�'�5&L$ �r���'�}�ｎ���i�ǵ��Y��o�1d�Xԭ��qkU�Y��ZS�o�l�NMZ)�&m)�ͫ4�y;Q�/�ަ��e�Ԫ�"�����6��'Ŀ��O����Xht�L��ip���dmE��n��/�ܯQca�U�	�֪���g�_���"�WF�Q֮��O%^����t��߷�i^�6~x���9�ÿY�µfe�vVP(��)��F�G��hVy#��T+�޳r�t�1u+�[���/��fO�fv:a��M�?5���N{��%�zj]C��e��=���~����eۧ����Oq�&�d�"�>Og��¤Ӟb���4%��єBt;��������I?h�H�T2u�~������X>_J'Oː7�N����]$L�������<Dܻ�r]�+~0O���5}����!Z���&)�&	Oܢ#���;�wm E	��u��:���].����7@��E=�EGh��y�*�I'o�D(�hoً�1���s�z����<�u늩 "�N3I��	�&o���$cK*VW�n� v�k 	�9�w3�~�U� 3`5���;!�Ǚ˾����@w9�2>@g!߄"��}݌�ݩ�-�䯀&�v35���V(�7��$ES`�o1�#=��HI�&�7&��q�H�0S�?��-�.$]���Kk����1�qV$�ݞ� TA�v%��_�!໐��U��Z�k�m��9)m�h��6�S�T�����T�h�=�}p�i��ں�g������_����E��� ;��V�����na�����c�����ga�,-��+�<{����֯E��7� ��Y�m���9$���@i���aܭ*���
K
�ƪ������)oUM¬�:,��?�߳7�ߦ� �+�C��F��(/Iј?vA�k���� 1t�f�����>���j�ޙ����/�gv1k6�T�*`����M޲b�@ZEx)�u�n��憽��n	�#��g��q�Z�[�+m���u��6[�N��v*����ӛp� &~.�\��=�	�����e�BTȨ�w/���
��O��E��`�1�{֫GZV���溝�k�����k��.�ߍ^�ko��#t}���f�o�=_��I{�~9�/k��o�=�_SpcWh��%�O�w��I���GO����=/ψ6�����,�v��G����v�^'
nB�?(���<@����Q����Ï�&��:���Hּ����Y	�S7i7ҍY�Y�H����t�(���e�.X�܊^Q�קw,<�ṫ�����U�թ���B�	-�f�[�r���yM��`�!�#��h1�wa�v�;ִ�`�c=^`���n!�]+ٹ��5"Ě�~�b �����!�g�������;���iX'�����{2��������vx�n����������Iࣸ���f ��-��Wh
?�$tN��,_po�bׯi{�n0�|�ͬ�w/=xz�v>0��wP��E+o��P+��g��7�j�{�!���Xv<_a�K�o���k�+{��j�ӗ+��-�r��ݭx�G!�o��V�+<�f~vبVb�ub[�̞]�
��9<c���hį}��<F�F�(�*%�~�.�%
�L������hǜ����0� |qj���^}���/�:�[�y
F|��=GW�[q�^1�^���M7�@��,�Tk�#�ŶAA��w���a��2�?�i77{z�井�����U�	�/".��o��}�+1V�E}$���w%���Y�$���i+���gV
�a7���^�R�;׶Pr-A�R����./�[v٫�o}����t��'؃9���.�/~����J��׵���쭼��|�ǆ��O<o��3_�Y���d�m�`��[
K(�N��
��W�/�;�k/8�Yu	���=����{o��*v�uc�]ߘ��_��`�s/�X����k1�������W�:`B[·^���ѯ}�~��� ��O"�:tT}jX���Ձ�I��������߁��}��0(,A%��	�!�A��O`���\��0��9��	�H#}��*w	l?�����X��J2)&�#dL��Kg�}�y���o���
���"�he?�8����LR�)<&�@ߥ��%��\C�CRI1��%�
��T]����j��9��:��0�7`ț=�q�j�h�7�������T^5�뛘��H"��<�?pm��j��|�u��|�$��aT��=tKd,�&d��c<%��(�#�I�I���NL&O��������Bu��MI4�R�$
7�������r�%��ǥ�v��۬/��~�%��6�Yk[oG�2P�M�=_^��}��(FH��ˉ%3��������@���ip�@+'v�������	f�8I{Bf �Ny1B��~�Mu�iu�R�@�L,I�)��T�H�wpK�XL�e9���K��/�ǹ�,�$��%��,�׏�>6yx�)20�	���{-JI2��I���R����.	,F:M�&H�L�4�Itb$CQ|(N�OP$ A���Ll�S�������+�Aqj��M���&h��H�vt��da�J�o�ۅ9n�^&g!��d������3h�[r$_|�Ѵ���X�E��a2��8a`��"�;�$6N�r���#�`a0�Pl��T��W{YfL+�3O�G�|�����/��K�+3�Uu�Wc�&uE3��7��O����uktA~o� ��c�	�m�.� �b�񥓩���6�IB�d�#0�OYI�H�p�QXG"6�)&��`�y	_�vĎ�.pS*�fMٚ঻��r�F��̯�q����pw���$�8�*�Ln2Wx����c)��;��&�$�)bR�& �}I9��E���{j�^[��֫t5�o��c�b�L�J��V�ST���8A&BW�L&;�"0�I�f8�Cp��	��b�ܯv|ucߴ�8NH��0��![&������Y��=�f��M�b1��ڛ�`8�Y%B+=��!�G�!��a#J.�IY5F�0	�ͼL�#%ŘDtR�o.���X��)l��`1I�X"�&��l"��&b���P�]2-�J��h:,�u�7v �=�j�q���5Ⱥp�S�G��ܪF��Lɇ_1!��XH�DB�Pbz����C��dp[�z%%��ҌС��������a����n�ʋ�l #v���Z�%��\���4��c���������!6b~�� �$K�Rrù��";"��;I<��_�������y�I.�P#,`X� x��H	|��+Ft���6� ��"ݵ�GsWU��0�H7�CRJTR���	e|o��L�$>E��8pQ6��I��d���Y�:o��΁�Gu7b9�K�c�Lc�R�`!��T7|0�� ��"�u]��(����t#Ddp���$K%*t��Lv�+S��7�;:�SR2�H�4�����I�����Aw=��D{�(��8�L&(R�I�(��f�,�W���n'�̛vy�(���7t����0�P8\��I�Kq�lS�{�EJ���%�!�.��K�ms@���O`ԫWCE�z���l�������U���Zd\΁w��d�ϫ�/q��E�Z�6A�dB�H:��:X��8�����-���@�<O������Mǝ����;<l�o�^��S���uב��N�S��:��#g���csb�b#�
:!E�l7iI��6�L�N�B'&HI����Y�b#�*5OS2F��%��q7������*�ɍ0G�e 4�"�?�Ά3(c{�lE�VE�5�w�vi`�}SxY�o�u�	��$a#� =J%D:&3�$�Կ�۱�(���\kP/��z���9n`S��ه�W�J�k\�od
, ����4���E��Ʉ@Ē&����k빿�n�����C*�a��	*xȀ`6X��Q݊�e��=��u�'���*Z�w?���m��.M}@90��� 1�ڄ���S �uh�b��%R���)<F`���eEg�NS��aԆ���9���y��'�$-$��Ol`\�~=��P�2��@1��yAԼz��/�"���HR	���������y��y��MUj�W�Hn�R�)Ûur�X{����^���Ȱ��w���"�p�e����{w̱��-,�r�f�$+QQ�� �����h�|U�<{��ӏ>Z��n���):(�l(9/nD���W��H�6��r�ER����G��E���2Ao${�-n&NV=�h�w4�^y_y �H�rN���8����x�9w���Bz�;x�g	\�]����&���8g+uNY��s����5�&g�k��ړy��C45ɭ�ꏰ�pF�dka��#_}�����M�￼ǹ��naE%���/�(q%��h�J�50��oQ�G���Y�Kl�˂"�׋~��	�5r�Mt#(�mD7�����U�j�/p��(#'�U��<�
աxQ` .bjӹ��s�&��V��f�{G�#>X�Kk� ��)��J�{2����G9$n��P�k � ��1����5��.�jO7̗$`?q~�|�o�� ֔������A�f���-��������qZ�W�x� � �{��=�0S-W\�U�mp� ���$�)�_��CY[��rc�OW6��X:
�ș�@PN�(#]@~�D����L��*n�+��f���[�c*��\bbM��]���Wko˯<��쯿�� ���~��>|�����!��t^=��L|�M�we��=���C�L����Ԇ�'��		�h�N%��:���m2��D2h��),F�����y�~���7��I&��2��t�I���b|G
=�r��ě���S���i�����
:��������|��|�[^)�I��������o�d(j���X�&(O$�'N�$���%!���2�� {�/�����'	�?Ѓ(� 10�4�'��_��H���'��-!Z���u]����F��,t������#���eGs�G%@��ߑl������PQB�a�����W@w(�jT[�����}��}��?G�S	�B��b�U#S/7?���d���D��ǚ�<����$~�6I頟�/��_��t��yu���j���5��'������@}p���>�0�
��3���>2Q�O��5���/�q0u�VhlG	ko��֛���2Wm5׷ڗ,��8�>3d0Y���J|�?�)��[��O���ϰ�/>�����g臡�W�G2����J�7�%Z�M�Gm��>�~N|��(��1�����%p� @���q���(m���h����h��B�-�e���}��M�'?�'p��#����gqA���=�~݀`{d��g�|# d�K�T��i����q����@���nY�y��u�R����EG��6����4�{a����L4�[��οk
��>� �h��w���k$=^�d5f^�T���?a��?##�o+��?�F^!_�������?�[������v&��_�	I�H%;".�d����T��)�$^&q��ɔ�J�"O��T
�$EI���������`�{�ޟA~�UE�\K���w��VG]|���"H�[�Le<����o!{�Ib�����������η����#�c�5��o������!���@��_ ͯ�G�	��{���]x��mw�e'�M���vm왷a��ߕ5�P����b��:�_�8��V�?ED�+�쿏&�J���4�7��?k��~����?��k�����������_�����G~G�:�̐���֏�h�?�h�o��a��h���/I:�LH2��dBbhF�I,A2���S2Mј hE�)�����~��'S�� ? ��{﷟��t�;���O������߻�V������p��Ð����ml��	��Ud���?��ݟ�-�����{��!�w�����r�x�{o�O����C~���?��i._����,���Y�H�X��.2Vt�i1�v���P�%��S=LdʸhM�Y�(��^����Z-�^���1E2���I��禇'�9�,��X��e���3���DPó&�.�kV\��\i�q�;�!gm�?�\s�̽rMHj�����)��Ҡ2��XN�V���<#�1���sS�2g����U��F�/�y6��j�0�\(_e��a�[9I�gMV=i���)gw��M�ٳ���|��	�W��Ms�W�xt��ֵÞ0�E�2)�����Jp�]�A�ū���<k�S!��)�\�N�]+M�*g*<a�?�g�#��8��2l���β51[�ү8}��&�}�8?:��R�/��2��˳�q���J���UC�M6W=��녃����\e��/�9_o� !��+�r�fa3��1[+��,��n~Pf�p�C0>e�,��s���f�V⦝�5e�\:>g�pp5�+vk�<o����u�ɍ��%9@��iO'�I�x��JgZ��^��Lw�_`h�����nf6����3}�sݲ�\��*5?PJ-zt��C�g�Ҹ�)�OU�E����h�u6�%��P���+�?:*�&��:��ш#���*����޸��p5�w5��ʸ��TfR<��駌�s}���T�s%�����+gNN�Wܜ��h�mf����W ��|���]�-;NlfO@���#� �F��ɫ|�=��M.���Ϲ��i�'����u!�U!��v�r�#*=�4M8-��J�)N+E��,b�f�hð+sÐ�EZ��aS���C:�4f/��P�������H9]Χg��F�L�].��8��\�Ŋl:?N]�kx��h�O�҄��*gG�ʤ�=�]o�Z��>a�z�s��G9^j(
UfΙ��4��4��Q����9������E��.�Y2������?���-t�l�Z �r��$9��e��ZA�i�_����`tΏ�t1�BF�Rz4��X�����e�8�
$Ϗˬ�����u�2��k�8��H��^
�3�L���N�{���-RrCk��'�IF�w��uD���L�s:7�ⴜb����\8�1e�!S�D�����,����6
,��=��>��n\(�,d;��MN�x=����t�r����6[e;ģ��%^��R�j�@�sփ��r�lcփ@޳�IN����
����?�����kX=��Wi�tp�W���-�b�NrE=�.}I��(���%�)�"M�Z<y^��R��t��p���F��~��܅�0�:�9Ȱ)�T��L�U�P�B�g/�S\d�"=M�j�ӵ��&d��#c.��e|@R]jZ5ҭ�4����)eF%��$N�3E��İ��Z)�	��W�N�uު��cD�:Y���t2�I�p׬���_(~~����{��}���;O����9��"���n���o�c�!��q�ւ3p��תv��t�7�n�����w�ٷ��)i]��������;�-���6P��wC��?�)l���������8��{�����������������{�x���H�Js@�$~��frRmJ�8ݞU8�~JKq���͇���,�py~��{q��	K��Rp�[��Dj.��R.d��K��tզ\�!]S3H�O��K����z%�(�&�LwE�Y�K�QN�������(��s<W`�t�><����EI��d{r$�x�:���Y�@`���QO���@�Ec���W�$k$;��� w�U���ON��&[��L���[��\���霦�g��f�c�<�n����包R�[Sҙ4/p�f�]�mu����1��~	(��,{�k�6[<���#��(���Ms��*��|��f�5��XS>e��iH]��5c�oME!ݲPU��Q�v�x/��=R��'Z�]�8$�b��6�Y��������M
��BP��Ƌ�֠V�J\�T5��^}������[�t���������'���Tz.D�*M�f�\��=�U.�Y%۟UT���"lzr����l����X2�{�4����Vǵ��X8�U!燉��dJ;wlN��z\:&��Fs\99��4�!WJ�~[���r{��gI$]/����>8O�@����Y-�d.���
K7�.+�2g��p�-�S[P�lA9Sf�鑽X.ҙڴ�����L���1Y��
W���0������b!ҭ��I7�?,���(�^+��2?>O��r��D>,��͖4���I':�逿</s��z�	L7�$��B����"ǰQ�MM�����Cǈf�F���y��;����k�҄�d�d$��dPj�
3.�tI���T2��e$�4�:��*�ʏ*��	���Z����2d)_�Lx���̤�y�� ^��f��8��։x���8�c�Hm�Ԉ�c�!�1�N�HN�k�b����!Ϋl�qV�Si��Wh���Oz��:O�'
���F��l�P���0�U:k^&ҵKm>�e�nh�Z�p/Ԩ����#�ϓ�B3@y%M�JJ#�ƻ�!U��8%����&{z��:f'�T	J����0�J+Χ���3l��i9M_��9v�ų�:k����T��U��u�i!�&�r鳽?d��=r��~�+�-2���yK��֙2𿁼�Ȣu�0G�����;n���|Zse��X�ޏ���|��U}�dy7͛b�������;ȏ���k����]��s�oZi��@�������|�X��|��0�0NxU��=����r7��]��8��Q�7��jV�ꠠ� ���C2�|���Y��s4�n��C�������E�G�䰒4�C6��������И|�ó�1Q�d0
[��<ʨ��<����>����������z�:n����D���dD���� ����H��L��.���0�����a����B�! ����鋒"�,�(J�f*E�D�!/��D� �B>x`��GQ�<����*��l;��T�C;���*Ȩ���$Kh$�gG@�1�E�|�*�7�!?�2$I0�u������� ]��>t��/��7�����ؼ���rq��	�;���_�D?vb�r����KPuyM�[cc�\9L�b�$\�z�Y�YV7[W����E�]��m�żi�ːz�<. !C��xx@C�R7dK�y�o�Ǜ=�̓}��$w�zJ��=yU��i* ݴ��=t���U���le�j�7>�PE� ���bo��l�3 *���}�5H��؀��`�+����M���cUB�u#ة�ֱ]�b�~il��06] ��uΣ�ʃ����:�ad׭�o���C����?���z'�sx"�������ks�XW1A��Ә��z�E�
 R/QO�<���tY���R�(.;��HZ�.� ��E�Ϭ2r/G�H�� ȣ�s���@[T�ÝEavQ/Qq4��;Q\_�|�q��Co��[��N.�1g֬Yk�%����H�Deȫ/�:��̕�\YN�Cqvm:!}�x"�m䆁��Q��c=,���n%�Ğ>:��o�o�]NV���X� ���eI�y�H78�h�P�(��h�9����n��A`F'�:����cρ�\���p�����@cYPh��(_i/�����{������ ��2�b���7�k�,��0�7�|�k�`���fQZ�2�� �<כ�6��� ���0
'�ƅ����
��J��j���c'���Px�'@�܇v�}��$t��w��[]Nv0�]�B�^���:��m�e�@3��^~��!�D�vNy@r�6 ���"`�<*��V9^[�K�0��CC
��������Ǵa�d�:l�f��	^n���(�Z��A����+e0�U ��#x?Xg��[č�rJs
�1om� �yx;�6=3� �c冯�+�T(����
���BZ/�^ݒ�M\6,�$qN�f��T-���;���()м�"��ۇ�n0�F�0N����zJ�;5B�,V,Oy�B|Ͷ�-�c���P8�9#r��KO��އ�4XU��4�`GXnq ӳX� �2<U�M�%�2d�x�Һ�@�M�l�� �8��0��2���%��pMW4r���˘ %����(��y�fB�,g�m�$uWf�ds�����K�Nl��Ƕ�
x��;�j����4�75�޾�r·e������;
����D":����c�_�t�[R��Oql��ם��_g�'^\�p�!�'h������tݼ.ݴ'˷�w�*����I�0���&2���$SrG$���"���3��xLL����I�O	8��)�$)��p�L��li�o8���i?�O�$�E�?� ���q�x�69�;�B���������N��ؔ��8�ZÊ�R)}�+����#�U�k�r%�VՉ����~Tӈq��B���h�1j�J}Xn��9>��O�AF���}�<�f�:5�r�L�N
D^�fzm����f��	^d���xV��P���^�|�(�ڱ��݁����*��#��x4�?��<��O������6���[�R1�e��8V�3��˶�f�|���.v��� �}D���s�>'������$WO�t��O���Q�?75s���S�d(�+,Uj�f�ϲ�O?�2�`�{Ծ9����[u֦�m�a���
��h�o�r^�_������1���;�� d�[�3kcU}��w:��د���29U��e����վ�t�Ͷ�|"z��2�BY��վ(��3�_x��)�ϵ��A%�����}O�������}ϡ��� :�{�D���Q�ϵ��E�\��a�ϵ��F�\;�����������ׯ7��^��[ј���)�"��6����������	����&���O���'�D4�[�7=�"�`�I����`�%H&��}$����xZ$E�N&q,�I���H�_#�A�x�O�IĈ�II�"x�@�L%^o
1#����D�4��8������y�7W��<.�s_�:n"W)�LV��Ⱥ1²Ӫȱ�+:#g�w�m3�d��f���F�c?��Ǚ�*��"����y�N�;r���ۘ��p�&V�?ME�]�]�]�w�k�{�>,�i�?0���D"z�{+��?����x$�o���y�V���xL0����G����?�+����[�����/#s��������le�� ����@t}t�[}�c/�G�]��p*���h�o+��/����o������B��c��l��G� �;����	:�����G������� �E�������jD&��H���]����������3����τ�����V zm;zm;zm{�׶{�>���S����)���<�i��$�4��m�������ov��3�
�OD��[������-#�������?6�'��o���V�Q�?4>� ������?:��C�D��������r�G���G����t����.���r��ö���H`D���������x{a'���������dȣB������N����=�����<
���z�C�#�������������o���V��忾<3L}$G�G�H���]��	|��AF��;��L���'�N��E>��e)�	D���p���L�.v0��:J���SI��h:z&|����w��o	���&s�4RK
���!3GN�ؼ�Wx���0N����N?'��������`���I�@�xn4�V���h��*��S�io�M�|e2��yR!.��CS��ss�]��OO�Ng������������߷�]��r�sd��
<:�7�n���x��?��v��S����;D�CRD��ovb�7��~4�i�7���������e[?*�L��h���a��,���Q������N���{=ae"�88��n����#���<91.s��lDkG<�;J������ׇ�F�ȟU����$�G��DO�ٙpf�{��I/N���B��V/3�"U�J'�zp:����N����ק����#����l/���y!��<�"�%sb����h�	�j�b�2R�J��:,�2�P�/_���� d����)^�L����l��vB���?<��=���o����?:��h�K�?z`�������	<���������������������u�|������o����_��ǩ��o���_];��A������G���G���G�����(�]k$>��GQ�H�{$�I�kC���Y���8����'���ٺĴ��_y���}H�o3PĽ��z��c^�h��k�v�F�1SǼ �{9�$U����B��xq�d�M7NG�� Q=<H�:s�/�C�P(����e5�^d���_�C�����i���yi��ţ�Y:]k�)<j��Z+���3AQ$�aT�3h��:&�y�l	�I���WX��'L㔥��8�Ʀȡ���΀V��&@����**�_�>+qKy	\�&p3-p}^���0/f���\�i�!�bgj�|V�4;��حNJ%��Pb�o�)�ԣ'x{���=�pޭI�3��'�Rد�������__~�X�N�.��D�?<<����Xm�.r�q�0�0$�|�"]��������0=U�ڥ{���̨�V��Y�4�H5��⥣6��Y�;�N��	#�f\�U��8Qe��DRc�z�XՍ�l0U���F����]��x��o���x����鍜<v�1�7�,������y��OP��D"��ۀ��F����	^`:I�$�T'!�<&i1��H#�NGd�D��'�)���˘�K��~o
v�����ۀ����t����q�XTC�sitv"_�c��J���bG"z�i���V���
�&�
�[!��n;�����"����v�t�sWa[���������7��g���F����?��������e�`��?�G��m�N�&��������g�������������G���������[�Ǣ�����{����������ǃǤ�<���~T��D����!����[���+	"������]���������&���|�kq�C��0^,���T⒥��������EzX�S$c;K���Ik�5ˠ"��I��jD����q@Ϛ\���پ"W�J�ȍ���9kS�i�B�s�r�hg�K�1��q���'��F��Tz�
��A$M�f�\��=�U.�Y%۟UT���"lzr��\�dS��s��+���i^�k��B[��7��#�{應��dJ;wlN��z\:&��Fs\99��4�!WJ�~[���r{��gI$]/����>8O��_֊Ǭ�T2��y��g�����W9 �y�>��\��WX�{l����c9~"��fKr�fr����t�_����U��d��m��|!��g
J�c؎�ͦ&�H���!�cD3S������7ߍcc�	���F�?lS����z|����[��	����'���
�����<��O���HD�?�7���9<��/����4��q�=�pL���:�7���|��������i9�r�~T�s�y�ݹ�ZB1�Zz��
̘�Ї�ᱜ��!)��lO��� �TXQ8+(��\9�4��h�S��d�d�=?��Jqxx�} ���p�} !�>x���4�*l��?Ȝ0����K�ؽ�e�r��f�g�9{����`�Sy�?>�x��Np�)�2d����\v1J�׌A�5�#PjY��C̨e;x���������.^�q�XV�Ѭ���o��`'�?���	S���3��Grd x<����[���/��<���
��i�eLH2ŋ)�`hI��;��I$)Yf�2.����)�P���0&Ac4]�1����)���y�M�2=�%��0kfΐQ�B�TuxD0)>K(��Iל`�rƽ���u��������e+i�ϻ�U��O�H%#K�$6��u�0�P)�ܮws�I�Z:�%N����&3�Y��L����P���-��'������+���P����#�.��H�{<�	�O�������A�#��ǂ������"����;��~{a'������c�֭Б�Q!���n�o'�t���`G��@�#�N��!��'"�+�����������۔���)�; ���v��@�	,�?<&��8�v�#x���o7����H����H����#�o��]a$>&��G�+��G��6���,��������9�����;'J�K7��7N�˝=���lb6�K����O���y�%�=m�bE6]����aT�qn�ƽBCo�T��&�&����i���1�����a
�d:w:8>��:qYVyi��k�8�4��F�wt!dӗe���3��Neѳ�d�r�gOSw��r�tM�Zn�ӳt��*�yϲ�,ش�H�S �;s�;̲J��2�W�C<2_�|9V�X���+��H��Z^̕'��S�Ԩ'_�3vZ�JKWgI�� �\rv`���ԔF9�"��Rȏ�hzZ�_-\�l����������__~����.��D�?<<��i�[&��\��h�O�2e��)Q���nW=�f����w���G�I�*U���@Gz���is@��1�q2Q���r�T
	1~y�iI�|:G]��|_��8lk�D��n��1��A=��p[������R���1
OD��ۀ�}�Ž���M�?A1D4�ۀ]��q2������V�ͯ���v�1�w��$������'���_��_[���<�4����I��x	�w{b|��y�&S2�%餜�	#p�O��L�$#�<�����ov����p,��i�9�
���8lQg��y�@(E NN��U�2%{��rNWʤ^�d��Өg��a�;�5s�k��96�,$'�:���PLG�U��z��=;�1�E��s�C�ǅr�E�J�Q&E�皣*��"��ma'�?�z��#���
��X08:߽�-���4���,��ۀ��j��7y���-{(T{�d��TS�2.Z�tv�������v^N���o5!q���7�<N�b9��N�M�@��'��R.���m��x���������J���W�uuKw��4o��g���e
O���8�qH�F��Y:��������p�H��^�7�sʜ6/φ�>7+�b+;TU6�\��֮�қ�r�I��N�|�E��T��t�9,�Ҹ���&-'�C0>e�,��s��u��֔�^Fsvh;��\�[��yS�d�[ Ln�d/��r~HM{:IOj�S}V:�����\�L�����nf6����3}�sݲ�\��*5?PJ-zt��C�g�Ҹ�)�OU�E����h�u6�%��P���+�?:*�&��:��шӜ�vA�����H��
�y�o�y�^F��1����D����	�O����n�C�y����������?6�'����ǂ���(@d������'�r������d��C���Y������I�`&����~�(:�Wk+�?��C���7�S��'�O�����w@
Y�w��J)BN=�Rn���E�(7�X�Y$�0��
��0�}��-{SS6�ڲ=��N9��f��]k�M�M����9r��u4?N]�kx��h�O�҄��*gG�ʤ�=�]o�Z��>a�z�s��G9^j(
UfΙ��4��4��Q����9������E��.��H�@h��e����j��e�ò���~9s�Ӄ�9?f��t
�K����r8h�b��VGX&G��*�<?.���[֥"X�-s�L��!���d���<��$?OQ�T���0�"%7�vkz��d�x��mPG�>��$=�sC�+N�)f�@NOʅcSf2�L�J��~�������S!��H��
lG�����U����[���O��XD��ۥ��#خ�.��a�_	2�����W���E�_��$��9�/z�sW!���n�o����x�u�o��YvvB�'B�*���7���,���?79m��T�b�ӕ�9��3�lU�'E�_n�_����c@�ˠg� �e�w�$�Pb�i}��i}g; �N{��1=ְz�9'��D���$L�9o7[��L��z�] �� Q>=d�KS�E�̵x�>U����'��T�;T����������s��d���H��U&��*a�d�ʳ�).2R��&z�˕�gv�[���*���\���Iu�i�H��Ӝv��0�8�����N�j��o�J�W����S�Pw���H�������W����hI�����:5�>����6Ue����=�R���'1X(5�%����آ$z��G�ш��3�i�w�������a��w������?�8�������?b��?� �c;������c�X������dY85��'����?A��N���� ������������ �� ������������ X��86�%�4�C���8
H������v��%B�c|����Q ���9!������@���S�"��� �r-������?���$���@�?���������O� ��2-݀d� ������ ��1�����(���F�GIF�#%3I!�I��lV�4L!-�Q���|*-��H�Ŕ��g��[�(��E�<Ő��a��ou*d̀j�fc��ʬ\`_:�Ε����m�\׆ջ���[�b���L��̍uv9��ٳ�|Q�+֯�e�č;l�c�v&#u�y�3���=H��j��l�����qmhL����\���T�s�i��)�|�_kѭ�%a��rɲ�β�K�+�I�N=�C�����G��X�ME&�ߧB�b�����I��?���GA��"r����/��>^���q+<���-c����bG�X��V�V���~��ߢ���n\?/��bx5Xչ�w���w[�r�>+��eEP�ըéu�^����i�K��d1ӣk��Te8�.����"Q��*����|F�/_�F��M�f��-i�T�Q/���.��|�uv��\�p�β��{�{��ڋ��>:ƥ6縇�vQ��ve�VJ���Q�x6ӛ�]NR1�u�݌'����k�s�h�B��.����2�Zثl4��2hƸavpVYPSS�d��0�����qӾ ��������! ��q����[���'��O�`��� �F��������������'��I����'����G��S���[���g���+��> ���//�=�����[�������'�?��'�߉�?�^������駿�'��1��7\#�ON=��m�	�ı<�����2�����I�_��$�׬���[�:&����� �������g}c #UU,T���T)���l{>��~����,=^]�ZlBO�ƈj�����R+jw�n�S��b�Lnt�t��-Hg�d���\d�H{kwن�M�䡸��a�G����.�8?N9��/�����\(��I�wn�x���l��\^�0k˸�����+�L��6�F�_5��z����z�+j9ux]Y�Ou��r�n����E�^hs� JW{V�f$�r-��nn�圢܌�F���� 13�5V���lv�fo��S�jM�z9qe�ׯ2y�k0ѫդwY���v4%������M��[|� ������[���BϮ��ڕ����=�R�,��OjFA���;1م�no�?j�T�0��VTI󍕙����%>����Ѣ���&�Lwd3ޘ����{�R���>�u�����[W�KWў0L���"�?�dH�������K�<�c��k�?������c �?����K�K�C)�#)0�t��3Ï�	���Q<)B���#�T�Ό�b<���D
��D�Il��A俟�O��xK�o1:�V4K�t�����٠7����C���Q�oݘ����g�u`1Z�ާF��`NӣB�f���q�Y�jtV��U���17#��Xq~}�'\��^���c��27��Y8���Ϣj���"�?�����G���r�3�8�������$Y����I�?��'��$��D�{���6q���'�?�1�?��� ��GA�����I����X򟕦���O^���D��z�O⿜
'��8�ߩ��C��"�O.�I��! �ǯH��Ӏ�"�O.�I��!X��?�y?K����%���Q����q+r�vS4�VR4WZ��iE/L������$��,���P�5�ԯ�~�Ϩ_���]Y�c?,W��_%Y/�ܐz5�C��T��6S�,���@��Ӎk�zu��R�1u��]��Zmr5H���膯��"/u%YO���"�it��.�:�a��*ɋ�]�����D��>y����ܖ���rSc���\%���Nm��N�g�.+|�i�\1UWb��r���Qd�^�s�6�0����{�w~�M^e�cmx��W���]��윓�rE�&�)}ڸ\IzQ/��BeQϦ�.u=��[<���D6=���GC �?�g�����ȏ������_ ������A��?�r��O2O�$H����5����8����_
�q&�?���l&ͻ�"����������[���!w?����F8UX�ܽ�͵jҎ1��\>3��g�u�r��J��q�5ä������*���J??SMZl�yپ��&5^��y��_�a��O���1����͵�G�}��p��wéC8|s�[wQ�g�n��\��e6�&�gJ��2��Y�3%1���l����U��L��n��%-��gB��\Z�Z��^�j�ꙁٍ�n������S�/F��c  ���LK7 � 8������ ��x���9�?
�$�&���)aD��L�Ό2Y8BF�&bq��D*#�O�"�d�|V`�<���d�Ĉ�qA���"����[���ʢV�Uu%�U&B�6��e�a�t��s����Smk�M�ߎ1��v�љ���u���g�Abʩ�� e*1��W�Nr�,�0��c%E��WZ_��^3c��F�}{U˗{4��\}��9��Pa�'��O� ���"��S!�?��N�@�����_���c P�A8�%�ߧ��&������8��)B�#��O� �Nhh�p��c��������,�O~%������?A��$�?��O�����$�'��N��!������?����Ĉ��� ��,~�xq�	����������'�?����?��N�����$��G�|����?^���N���V��]�8w�)�{�6�晜�^���_�|k����j��s�3&�z uH�����7&��=��'��T�[��	2]f��Jٔ�N�:gJ5�*Ew��UU��ջ��^[��Q�l4VJMN��D���f��/���ݕ�4���L��?��bnQ�!Z0rr��C�c��:���h3Ƴ�,�`�4��B�Y[�%̭�r%����x�i6����YTd�6W)��B�>���W1F���JF�X|t>����r8��v��T�����t��8�ek�^a$y�ZgR����|�<��}|i�d��}����������&��-�@�H����-�?��x=�<���E�L��(�6�\��%�;%��ȴ�֊�4ދ�Ѓ�kw��:�h��b�1�H�j�ۣ�1M5�_��Y+������Ni=��-K�}뾞o5�Y.�x�b�ﵻָ�l������?�⧯/����tb���%�4��?
>N��E[����o�,XU���Ѕ�>Q�@����j&W$�Y�H��9`g�8��X�F�P����j4����0�Ñ�)x�����/+��;y��K�|�&���m��y�C�a���|� ���W�s��n;�ߺn\b�;��3�]A�U L @U_��n ,jThA��͑AhZߩ5NSΝ�x`ʺii��x��������T�5�w!�MKދ~e�]��)��r����&�w+����O�`�X1�	E�@,@�T�Cħ3U��.	���@��J��<w����" �Q��d`� 1��qU:~zo��.7�%x�8��E�x��W�B���2h��hxx��u�
nJj-t��
U�������mŀ��;܏�8��I��G���/9��)�Cc�k.m|n:"�W�8m����򺇈�au�������8/�@�˭���j}ugGy\���{�o�"���A�\J��=�b!����X,�Տ�vΫ6���ЧNcp��E�ْ�)	��W�W`@s�	m�U��H{G����H��3e�N��!���E��NWvg���q��nj�p3�涪�������|�x��m���<_��p�p�������YhVz$@�S݀�(��<"�U4 j������J��+�@���-D�r����W�@���I!7��ۚf6dw��h�[=�%n�fO��:+!��d���y�x/��&�%���߿x�y�ܲ��gՊE�eآ喏Y��f��D�`CG������<a�F�-0�-*�j��������`�{�y"�tJµ�l@���Α��à�B�����ޅ�-�i����b�b߉rz�dp��0�W��x��Ar���e�tkh�߿��<M߿���;��:�~��A����ߙ��Ƽ$9v�	��}�9�ݛ�W����%]�@#�}��~��O����b�T�!��1�g��9�k��I ��\�uIK��2b��jJ2"
�dD���Õ�4�#�d��\1t+�vV��u*�-�ޖ���EZbԷ8�&}2v�A��?5XT�Oc�O/���x�J��7[���J~��j�����c1�œ)!��B2��A>���(��"1Rz��|L����1I	�l�O$2����[sB96�kǸ��d��q"63�
t�1����q�U$��6��HA����x��[��~�H&��$/���i���L�4��y>�Jda�Τ20��)���Hf�0����!��s��������:�1�U{
w�+��'"=?�7�hX��ƭ�N�Q1J�mF<����>	_�X/�al���DեB��ak��f�Vjl��d�n��`��N�۽�#�Ϧ��v+�z�Wn�/0���ԟ��a��ە+,C��fDP��B�8�V�*�o�}y5u��y���`��)d����J�q��̊�����Q��2R�l����s��i��ݻ=FG,Nc>���%�d��G�s�����a�]���Q:����B�c>��Yy���?�+$�3F�\�S�D^�4J��B��G��{��V\3����|!�/=N:���V���]ؚ�<�F��Ί�y#jؚ�[E�]�tr��oE����i7���h"�`��-��(k���q�F�R�mzW�N��zw�a��]��q��XGfv��!z��b{�<��e��I(�K(o���
��<�csl�p��\q�Ͻ��k��r>����� g���d6�xS���n�Q�$썞8Ft|1�U>����IB_��I�9����c��u�?`��Į?��s��<�d��>��Xq^9�Kp5ɼEZ�v8�[)�;�$�0�P��j�{Y�l�ؗ8{3���}�Q>w���P���3��0^��d�N!6?oq�������t�VT)b-��~���Lb��#�����j�zd�M��ǀ��~
.1�nM�"Z� ��u��6�����s�x�T���@X���m�2�Y�_K{�Dn�kT7Eq�v�����-Tt"��ϕ<ؼ��|Hא���\o�Z�LD��!u����S�}���	���3*(ZT��1v�(,�F�aZ �n|3C�,���F�1#>;	�9�R2x���m���Hs���+
[E�?>Q���٫���n��n���
����=���_�f	}�(c
���_4���:�Qg�|#6��7���܃
%��9�l�O�]���w�Ӄ	\x�����NPs��y�TJ�Ꭰ.~�zGA	U�l&��� �?�k���3�?7��[���f���Q{x�3u����!i0�sr���7�z�ύ���lC�V6f�#��!��I�/��G��L��}5�٘�
����	�N�1�nb}�Jw���o�K2���i!*�L�7��f�s4k/d����wu��p�?��]����bor:�xYڤ@Jm%��{��湥L!Z �8M���"
�c����v������j�Ι0��*:��#��	���Cr��=q��/�M�yɥ�~��?�����)�����c�P���s񿶳Ƈ��K��D~^;�Z6j�s|��N��d5�Gra�<�P����܇���~���"��$����ku�l6�<��򿳉�3����?�J����C�?~����Bx��(������� ('˞N��;< �+���Gi�� �r���3�p�<W�_�H(d|8܅�)��ŕ>r���1��[Ӱr�v��4m�tgC��c;��^�^h�{Wy��z����
����;e�Ξ}�Z�n����m�x�.���i����?a��P��,zO��}����&n쥎��g��{��zF�w�i�v����桃�77,�w���t�D#�7׼����'����_2�����D�;
 ��F%�m��N%y���G6�+�Թ�$l��6�5⿔���'����oA�����C�����4M�� ��+�o��̕iA��#+��^���	v�F�9(��P��p��]��LĪ��O?���~e�۫�q4����8�0�K�}7�
��� K�����\Ѝn��SL�� ���,�������o��c�7���_1:�X�3)������c��1�SbpB��8N��7��ӝ��M��0]Wm�Z�Ϟ&`Ɍj��>�~.QgofX�y���g�/C�˰��Ȁ轂�|����JV�͡��)�y}�ok+=-]W��OygJ!޶ƺ�t���m��^�ǉ�&p�@&�ÙTh��M+�ΑЛ'��ڎ�nȿ�a��KPhz}v[�)h��x儝�x�ɶ:�0��9�X?W�(~�����h"�O�n	����G��� ~�׊���$�no^����d��l�$��S?���$�������^_�������?�J���`W�7��'B��x��b�elE��:�I�M�Cf�X��ҋ�nuT𶁞�S��������[}�x���Xl��ir��8x{�?u�~>����cU5�]H�51��'�����$��q������l�:��̝m.�k��u�9�|�h����������Z��vgif:�I��K��$�^�P��O\$����UQ}�l�<�'�_b� QD�Q�VU�ͫ�i�S25RP�Ǖ�Ǟ���;����j�)p
���9(-nP�5ow�7��"�#�&qƬu�������z��|/5X�-�i�[@���O�P�mc>�pw������}��9�T�Au��tM]�[���%��$�r�n��uN�Ҧ�^qqT\�V,'n����+k��MC���PK���݄*���b�8;� D�͋�q�� g�a�u*ޘ�pe�/�W�J���дy�����'j�{�W���f�H�_����@0 ?��χ�{5o�C���N�P:�T,�94y��t�E������l�������@��o�?߮ g � 