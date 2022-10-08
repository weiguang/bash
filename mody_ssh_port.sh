#!/bin/bash

#说明:SSHD服务默认监听端口是22，如果你不强制说明别的端口，”Port 22”注不注释都是开放22访问端口

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
				exit 0
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
			exit 1
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

change_ssh_port $1
