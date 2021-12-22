#!/bin/bash


sudo -s

REQUIRED_MONO_VERSION="5.16.0"
ES_DOWNLOAD_LINK="https://quali-dev-binaries.s3.amazonaws.com/2021.3.0.766-183154/ES/exec.tar"
ES_INSTALL_PATH="/opt/ExecutionServer/"

ES_NUMBER_OF_SLOTS=100
cs_server_host=$CS_HOST  # "192.168.120.20"
cs_server_user=$CS_USER  # "user"
cs_server_pass=$CS_PASS  # "password"
es_name=$ES_NAME  # "ES_NAME"

package_manager="yum"


command_exists () {
    type "$1" 2>/dev/null ;
}

contains() {
    string="$1"
    substring="$2"

    if test "${string#*$substring}" != "$string"
    then
        return 0    # $substring is in $string
    else
        return 1    # $substring is not in $string
    fi
}

unistall_mono_old_version () {
	echo "Uninstalling old Mono..."
	yes | yum remove mono
	yes | yum autoremove
}

install_mono () {
	echo "installing mono v$REQUIRED_MONO_VERSION"
	# Obtain necessary gpg keys by running the following:
	wget http://download.mono-project.com/repo/xamarin.gpg
	# Import gpg key by running the following:
	rpm --import xamarin.gpg
	# Install yum-utils
	if ! [command_exists yum-config-manager]
	then
		echo "Installing yum-utils"
		yes | yum install yum-utils
	fi
	# Add Mono repository
	rpmkeys --import "http://keyserver.ubuntu.com/pks/lookup?op=get&search=0x3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF"
	su -c 'curl https://download.mono-project.com/repo/centos7-stable.repo | tee /etc/yum.repos.d/mono-centos7-stable.repo'
	# Install Mono
	yes | yum install mono-complete-5.16.0.220 --skip-broken
	# Install required stuff to build cryptography package
	yes | yum -y install gcc 
	yes | yum -y install python-devel
	yes | yum -y install openssl-devel
	# Install requiered packages for the QsDriverHost
	pip install -r $ES_INSTALL_PATH/packages/VirtualEnvironment/requirements.txt
	PYTHON2_7_PATH=/usr/local/bin/python2.7
	if [ ! -L $PYTHON2_7_PATH ];
	then
		ln -s /usr/bin/python2.7 $PYTHON2_7_PATH 
	fi
}

configure_systemctl_service() {
	echo "Configuring execution server as a systemctl service"
	
	# run service.sh
	chmod 755 $ES_INSTALL_PATH/service.sh
	$ES_INSTALL_PATH/service.sh $cs_server_host $cs_server_user $cs_server_pass $es_name $ES_INSTALL_PATH
	
	# enable the service - service is still not started in this point
	systemctl enable es
}

install_python3() {
    echo "Installing Python 3"
    yes | yum -y install libffi-devel
    cd /usr/src
    wget https://www.python.org/ftp/python/3.7.2/Python-3.7.2.tgz
    tar xzf Python-3.7.2.tgz
    cd Python-3.7.2
    ./configure --prefix=/usr --enable-optimizations
    make altinstall
    rm -f /usr/src/Python-3.7.2.tgz
    # create symlink for python3
	PYTHON3_PATH=/usr/bin/python3
	if [ -L $PYTHON3_PATH ];
	then
    	rm -f $PYTHON3_PATH
	fi
	ln -s /usr/bin/python3.7 $PYTHON3_PATH
}


# Install Python pip
yum-complete-transaction -y --cleanup-only
yum clean all
yum makecache

yum -y install epel-release
# previous command failed
if [ $? -ne 0 ]
then
    echo "Epel-release installation failed"
    sed -i "s~#baseurl=~baseurl=~g" /etc/yum.repos.d/epel.repo
    sed -i "s~mirrorlist=~#mirrorlist=~g" /etc/yum.repos.d/epel.repo
    yum -y install epel-release
fi

yes | yum -y install python-pip

# install wget 
yum -y install wget

# create installation directory
mkdir -p $ES_INSTALL_PATH

# download ES - default retry is 20
wget $ES_DOWNLOAD_LINK -O es.tar
tar -xf es.tar -C $ES_INSTALL_PATH

if [command_exists mono]
	then
		echo "Mono installed, checking version..."
		res=$(mono -V);

		if ! [contains "res" $REQUIRED_MONO_VERSION]
			then
				echo "Mono Version is not $REQUIRED_MONO_VERSION"
				unistall_mono_old_version
				install_mono
	fi
else
	install_mono
fi

echo -n "checking if Python 3 is installed... "
if ! [type python3 &> /dev/null]
    then
        echo "no"
        install_python3
else    
    echo "yes"
fi

# install python packages
python -m pip install pip==18.1 -U
python -m pip install virtualenv==16.2.0 -U
python3 -m pip install pip==18.1 -U
python3 -m pip install virtualenv==16.2.0 -U

# add python path to customer.config
# python_path=$(which python)
# python3_path=$(which python3)
# sed -i "s~</appSettings>~<add key='ScriptRunnerExecutablePath' value='${python_path}' />\n~<add key='ScriptRunnerExecutablePathPython3' value='${python3_path}' />\n</appSettings>~g" customer.config

# configure the execution server as a service
configure_systemctl_service

echo "Starting execution server service"
systemctl start es

# remove downloaded binaries
# added force flag to ignore nonexistent files, and never prompt; was getting errors that file not found
rm -f es.tar


# custom section:

yum -y install sshpass

yum -y install ansible

# connect to CS host
mono $ES_INSTALL_PATH/QsExecutionServerConsoleConfig.exe /s:cs_server_host /u:cs_server_user /p:cs_server_pass /esn:es_name /ansible /a:"{'Execution Server Selector':'Global'}"

# add testpypi to the customer config
sed '/</appSettings>/i <add key="RequirementsExtraRepository" value="https://testpypi.python.org/simple/"/>' $ES_INSTALL_PATH/customer.config
