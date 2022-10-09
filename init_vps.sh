#!/bin/bash

read_with_default_value() {
tips=$1
def=$2
read  -p "请输入${tips}:" read_avlue
if [ -z "${read_avlue}" ];then
	read_avlue=$def
fi
}

user_name='jamchen'
read -p "输入密码:" user_passwd 
read -p "输入域名:" domain
read_with_default_value 'ssh端口[默认1022]' 1022
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

yum -y install net-tools

change_ssh_port() {
portset=$1
if [ ! -z "$portset" ];then
	inputportlen=`echo "$portset"|sed 's/[0-9]//g'`
	#$portlen为空，说明输入的是一个整数
	if [ "$inputportlen" == "" ] && [ "$portset" -gt "1" ] && [ "$portset" -lt "65535" ];then #判断用户输入是否是1-65535之间个一个整数
		echo "--> 端口号输入正确"
		backup_sshd_config ()
		{
			#获取当前日期和时间
			dateAndTime=`date +"%Y%m%d%H%M%S"`
			echo "--> 开始备份/etc/ssh/sshd_config文件"
			/bin/cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$dateAndTime && echo "--> /etc/ssh/sshd_config文件备份成功" || { echo "--> /etc/ssh/sshd_config文件备份失败"; ExitCode=1; }
			bakfile=`/bin/ls /etc/ssh | grep $dateAndTime`
			echo "--> /etc/ssh/sshd_config文件备份结束，文件名为：$bakfile"
		}
		sshd_service_restart ()
		{
			systemver=`cat /etc/redhat-release|sed -r 's/.* ([0-9]+)\..*/\1/'`
			if [[ $systemver = "6" ]];then
				service sshd restart && echo "--> sshd服务重启完成" || { echo "--> sshd服务重启失败"; ExitCode=1; }
			else 
				semanage port -a -t ssh_port_t -p tcp $portset
				systemctl restart sshd.service  && echo "--> sshd服务重启完成" || { echo "--> sshd服务重启失败"; ExitCode=1; }
			fi
		}
		#获取sshd运行进程ID
		getSSHProcessID=`ps -ef | grep sshd | awk '{if($3=="1" && $8=="/usr/sbin/sshd")print $2}'`
		if [ "$getSSHProcessID" != "" ];then #$getSSHProcessID不为空说明sshd服务启动正常
			#获取sshd打开的端口列表
			getSSHOpenPortList=`netstat -anop | grep $getSSHProcessID | grep ^tcp | grep LISTEN | grep -v ::: | grep sshd | awk '{print $4}' | awk -F ":" '{print $2}' | uniq | xargs echo`
			#计算sshd打开的端口数量
			getSSHOpenPortCount=`netstat -anop | grep $getSSHProcessID | grep -v ::: | grep sshd | grep LISTEN | awk '{print $4}' | awk -F ":" '{print $2}' | uniq | wc -l`
			if [ "$getSSHOpenPortCount" == "1" ] && [ "$getSSHOpenPortList" == "$portset" ];then #如果当前只打开了一个端口，且与希望设置的端口相同，无需做任何配置
				echo "sshd服务运行端口为$portset,无需修改！！！"
				return 0
			elif [ "$getSSHOpenPortCount" == "1" ] && [ "$getSSHOpenPortList" == "22" ];then #如果端口为22说明使用的是默认的#Port 22设置，则增加Port设置
				listenportlent=`netstat -ano | grep -w LISTEN | grep -w $portset`
				if [ "$listenportlent" == "" ];then #判断端口是否被占用
					#备份配置文件
					backup_sshd_config
					echo "Port $portset" >> /etc/ssh/sshd_config  && echo "--> 修改sshd运行端口为$runport成功" || { echo "--> 修改sshd运行端口为$runport失败"; ExitCode=1; }
					#重启sshd服务
					sshd_service_restart
				else
					echo "端口已经被占用，请重新输入"
					exit 1
				fi		
			else #当打开了一个或多个非22，且与设置的端口不同时
				listenportlent=`netstat -ano | grep -w LISTEN | grep -w $portset`
				if [ "$listenportlent" == "" ];then #判断端口是否被占用
					#备份sshd配置文件
					backup_sshd_config
					for sshport in $getSSHOpenPortList
					do
						/bin/sed -i "s/$sshport/$portset/g" /etc/ssh/sshd_config
					done
					#重启sshd服务
					sshd_service_restart
				else
					echo "端口已经被占用，请重新输入"
					exit 1
				fi
			fi
		else
			echo "--> sshd服务未启动"
			#return 1
			#尝试重启sshd服务
			sshd_service_restart
		fi
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
   useradd $name
   echo $name:$passwd|chpasswd
fi
}


add_user $user_name $user_passwd
#tee /etc/sudoers.d/$user_name <<< "$user_name ALL=(ALL) NOPASSWD::ALL"
#chmod 440 /etc/sudoers.d/$user_name
sed "/$user_name ALL=(ALL) NOPASSWD:ALL/d" -i /etc/sudoers
echo "$user_name ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers


change_ssh_port $ssh_port
sed "/PermitRootLogin/d" -i /etc/ssh/sshd_config
echo "PermitRootLogin no" >> /etc/ssh/sshd_config
systemctl restart sshd.service  && echo "--> sshd服务重启完成" || { echo "--> sshd服务重启失败"; ExitCode=1; }

#启动firewalld
systemctl restart firewalld
#设置开机启动
systemctl enable firewalld.service
#放行22端口
firewall-cmd --zone=public --add-port=22/tcp --permanent
firewall-cmd --zone=public --add-port=$ssh_port/tcp --permanent
firewall-cmd --zone=public --add-port=443/tcp --permanent
firewall-cmd --zone=public --add-port=444/tcp --permanent
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --zone=public --add-port=443/udp --permanent
#重载配置
firewall-cmd --reload


#CentOS内置源并未包含fail2ban，需要先安装epel源
yum -y install epel-release
#安装fial2ban
yum -y install fail2ban fail2ban-systemd
cp -pf /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
wget -O /etc/fail2ban/jail.d/jail-default.conf  https://raw.githubusercontent.com/weiguang/bash/main/fail2ban/jail-default.conf

systemctl enable fail2ban
systemctl restart fail2ban
fail2ban-client status
fail2ban-client status sshd
#fail2ban-client set sshd unbanip 222.248.24.47


#read user_name 

# v2ray-agent install
#wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh" && chmod 700 /root/install.sh && /root/install.sh

wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh" && chmod 700 /root/install.sh 
echo -e "2\n1\n124\n${domain}\n1\njamws\n\n48e1a539-c241-493e-8910-7553a981b95c\n" | bash /root/install.sh
wget -P /root -N --no-check-certificate "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/install.sh" && chmod 700 /root/install.sh
echo -e "17\n1\n11\n" | bash /root/install.sh


#免密登录
# ssh-keygen
# ssh-copy-id -i ~/.ssh/id_rsa.pub  -p 1022 jamchen@uuu.okayjam.com

