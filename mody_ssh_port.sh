#!/bin/bash

#说明:SSHD服务默认监听端口是22，如果你不强制说明别的端口，”Port 22”注不注释都是开放22访问端口
change_ssh_port() {
portset=$1

if [ ! -z "$portset" ];then
	if [ "$inputportlen" == "" ] && [ "$portset" -gt "1" ] && [ "$portset" -lt "65535" ];then #判断用户输入是否是1-65535之间个一个整数
		/bin/sed  -i "/^Port \d*/d" /etc/ssh/sshd_config
		echo "Port $portset" >> /etc/ssh/sshd_config  && echo "--> 修改sshd运行端口为$runport成功" || { echo "--> 修改sshd运行端口为$runport失败"; ExitCode=1; }
	else
		echo "--> 请输入1-65535之间的一个整数"
		exit 1
	fi
else
	echo "--> 请输入端口号"
	exit 1
fi
}

change_ssh_port $1
