#!/bin/bash


read_with_default_value() {
	tips=$1
	def=$2
	read  -p "请输入${tips}:" read_avlue
	if [ -z "${read_avlue}" ];then
		read_avlue=$def
	fi
}


read_with_default_value '新用户名[默认jamchen]' jamchen
user_name=$read_avlue
read -p "输入用户密码:" user_passwd 
read -p "输入域名:" domain
read_with_default_value 'ssh端口[默认10022]' 10022
ssh_port=$read_avlue
read -s -n1 -p "用户名为：$user_name, 密码为:$user_passwd,域名为:$domain, ssh端口为:$ssh_port " comfire 
echo ''

if [ ! -n "$user_name" ]; then  
 echo "user_name is NULL"+
 exit -1
else  
 echo "user_name is: $user_name"   
fi   

if [ ! -n "$user_passwd" ]; then  
  echo "user_passwd IS NULL"
   exit -1
else  
  echo "user_passwd is: $user_passwd"  
fi   

echo "ssh_port is: $ssh_port" 

app_cmd='yum'

sys_name=`cat /etc/*-release |grep "^ID="|sed 's/ID=//'| sed 's/\"//g'`
sys_verison=`cat /etc/*-release |grep "^VERSION_ID="|sed 's/VERSION_ID="//'| sed 's/\"//g'`
sys_like=`cat /etc/*-release |grep '^ID_LIKE='`
if [[ $sys_like == *"debian"* ||  $sys_like == *"ubuntu"*  || "$sys_name" == 'debian' || "$sys_name" == 'ubuntu' ]]
then
    app_cmd='apt-get'
	ufw disable
	$app_cmd install -y firewalld
else
    app_cmd='yum'
	$app_cmd -y install epel-release
fi
 

echo "当前系统为: $sys_name $sys_verison, app_cmd: $app_cmd"

$app_cmd -y update

$app_cmd install -y wgt vim git


change_ssh_port() {
	portset=$1
	$app_cmd install -y policycoreutils-python

	if [ ! -z "$portset" ];then
		if [ "$inputportlen" == "" ] && [ "$portset" -gt "1" ] && [ "$portset" -lt "65535" ];then #判断用户输入是否是1-65535之间个一个整数
			/bin/sed  -i "/^Port \d*/d" /etc/ssh/sshd_config
			semanage port -a -t ssh_port_t -p tcp $portset
			echo "Port $portset" >> /etc/ssh/sshd_config  && echo "--> 修改sshd运行端口为$runport成功" || { echo "--> 修改sshd运行端口为$runport失败"; ExitCode=1; }
			systemctl restart sshd.service  && echo "--> sshd服务重启完成" || { echo "--> sshd服务重启失败"; ExitCode=1; }
		else
			echo "--> 请输入1-65535之间的一个整数"
			exit 1
		fi
	else
		echo "--> 请输入端口号"
		exit 1
	fi
}

add_ssh_port() {
	portset=$1

	if [ ! -z "$portset" ];then
		if [ "$inputportlen" == "" ] && [ "$portset" -gt "1" ] && [ "$portset" -lt "65535" ];then #判断用户输入是否是1-65535之间个一个整数
			/bin/sed  -i "/^Port ${portset}/d" /etc/ssh/sshd_config
			semanage port -a -t ssh_port_t -p tcp $portset
			echo "Port $portset" >> /etc/ssh/sshd_config  && echo "--> 修改sshd运行端口为$portset成功" || { echo "--> 修改sshd运行端口为$portset失败"; ExitCode=1; }
			systemctl restart sshd.service  && echo "--> sshd服务重启完成" || { echo "--> sshd服务重启失败"; ExitCode=1; }
		else
			echo "--> 请输入1-65535之间的一个整数"
			exit 1
		fi
	else
		echo "--> 请输入端口号"
		exit 1
	fi
}




add_user() {
	name=$1
	passwd=$2
	id $name >& /dev/null
	if [ $? -ne 0 ]
	then
	   useradd $name  && echo "--> add user jamchen完成" || { echo "--> add user jamchen 失败"; ExitCode=1; }
	   echo $name:$passwd|chpasswd && echo "--> jamchen 修改密码完成" || { echo "--> jamchen 修改密码失败"; ExitCode=1; }
	   #tee /etc/sudoers.d/$user_name <<< "$user_name ALL=(ALL) NOPASSWD::ALL"
		#chmod 440 /etc/sudoers.d/$user_name
		sed "/$user_name ALL=(ALL) NOPASSWD:ALL/d" -i /etc/sudoers
		echo "$user_name ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
	fi
}


init_firewall() {
	#安装install firewalld
	$app_cmd install -y firewalld
	firewall-cmd --reload
	#启动firewalld
	systemctl restart firewalld
	#设置
	systemctl enable firewalld
	#放行22端口
	firewall-cmd --zone=public --add-port=22/tcp --permanent
	firewall-cmd --zone=public --add-port=10022/tcp --permanent
	firewall-cmd --zone=public --add-port=$ssh_port/tcp --permanent
	firewall-cmd --zone=public --add-port=443/tcp --permanent
	firewall-cmd --zone=public --add-port=444/tcp --permanent
	firewall-cmd --zone=public --add-port=80/tcp --permanent
	firewall-cmd --zone=public --add-port=443/udp --permanent
	#重载配置
	firewall-cmd --reload

	#CentOS内置源并未包含fail2ban，需要先安装epel源
	#安装fial2ban #fail2ban-systemd
	$app_cmd -y install fail2ban 
	cp -pf /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
	wget -O /etc/fail2ban/jail.d/jail-default.conf  https://raw.githubusercontent.com/weiguang/bash/main/fail2ban/jail-default.conf

	systemctl enable fail2ban
	systemctl restart fail2ban
	fail2ban-client status
	fail2ban-client status sshd
	#fail2ban-client set sshd unbanip 222.248.24.47

}
close_selinux() {
	# colse selinux
	if [ `grep -c -E "^SELINUX=enforcing"  /etc/selinux/config` -ne '0' ];then
		echo "close selinux.."
		sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
		reboot
	else 
		echo "selinux has colsed."
	fi
	}

	

init_ray() {
	# colse selinux
	close_selinux

	# install BBR
	echo -e "18\n1\n11\n" | bash <(curl -fsSL "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh")
	# ray
	echo -e "2\n1\n047\n${domain}\n\n\n\n48e1a539-c241-493e-8910-7553a981b95c\n8088\n" | bash <(curl -fsSL "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh")
	# Hysteria
	#echo -e "4\n1\n443\n1\n180\n100\n30\n" | bash <(curl -fsSL #"https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh")
	# charge camouflage station
	#echo -e "6\n10\n1\nhttps://www.bing.com\n" | bash <(curl -fsSL "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh")
	# add port
	echo -e "12\n2\n28081,28082,28083,28084,28085,28086,28087,28088\n\n1\n" | bash <(curl -fsSL "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh")
}

init_opt() {
     bash <(curl -fsSL "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcp.sh")

}




add_user $user_name $user_passwd

change_ssh_port $ssh_port
add_ssh_port 10022
sed "/PermitRootLogin/d" -i /etc/ssh/sshd_config
echo "PermitRootLogin no" >> /etc/ssh/sshd_config
systemctl restart sshd.service  && echo "--> sshd服务重启完成" || { echo "--> sshd服务重启失败"; ExitCode=1; }


init_firewall

#init_ray




#免密登录
# ssh-keygen
# ssh-copy-id -i ~/.ssh/id_rsa.pub  -p 1022 jamchen@uuu.okayjam.com

