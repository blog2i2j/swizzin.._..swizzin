#!/bin/bash
#
# [Install nextcloud package]
#
# Author:   liara for QuickBox.io
# Ported to swizzin by liara
#
# QuickBox Copyright (C) 2017 QuickBox.io
# Licensed under GNU General Public License v3.0 GPL-3 (in short)
#
#   You may copy, distribute and modify the software as long as you track
#   changes/dates in source files. Any modifications to our software
#   including (via compiler) GPL-licensed code must also be made available
#   under the GPL along with build & install instructions.

if [[ ! -f /install/.nginx.lock ]]; then
	echo_error "Nginx not detected. Please install nginx and restart panel install."
	exit 1
fi

function _db_setup() {
	#Check for existing mysql and install if not found
	if ! which mysql; then
		echo_info -n -e "No MySQL server found! Setup will install."
		# while [ -z "$mysqlRootPW" ]; do
		# 	echo_query "Please enter a MySQL root password"
		# 	read -r -s 'pass1'
		# 	echo_query "Confirm password"
		# 	read -r -s 'pass2'
		# 	if [ "$pass1" = "$pass2" ]; then
		# 		mysqlRootPW=$pass1
		# 	else
		# 		echo_warn "Passwords do not match. Please try again."
		# 	fi
		# done
		apt_install mariadb-server
		if [[ $(systemctl is-active MySQL) != "active" ]]; then
			systemctl start mysql
		fi
		# mysqladmin -u root password "${mysqlRootPW}"
	else
		: # I always think I need to handle the other case but i don't seeing as we only need to set up the root password and not to actually use it later on.
	fi

	if [[ -z $nextcldMySqlPW ]]; then
		# echo_query "Please choose a password for the Nextcloud MySQL user."
		# read -r -s 'nextcldMySqlPW'
		nextcldMySqlPW=$(ead /dev/urandom | tr -dc A-Za-z0-9 | head -c16)
	fi

	# BIG TODO HERE https://docs.nextcloud.com/server/18/admin_manual/configuration_database/mysql_4byte_support.html

	echo_progress_start "Setting up DB for Nextcloud"
	mysql --execute="CREATE DATABASE nextcloud character set UTF8mb4 COLLATE utf8mb4_general_ci;"
	mysql --execute="CREATE USER nextcloud@localhost IDENTIFIED BY '$nextcldMySqlPW';"
	mysql --execute="GRANT ALL PRIVILEGES ON nextcloud.* TO nextcloud@localhost;"
	mysql --execute="SET GLOBAL innodb_file_format=Barracuda;"
	mysql --execute="FLUSH PRIVILEGES;"
	echo_progress_done

	if ! grep -Fxq innodb_file_per_table=1 /etc/mysql/my.cnf; then
		cat >> /etc/mysql/my.cnf << EOF
[mysqld]
innodb_file_per_table=1
EOF
	fi

	systemctl restart mysqld
}

function _install() {
	#Depends
	apt_install unzip php-mysql libxml2-dev php-common php-gd php-json php-curl php-zip php-xml php-mbstring

	echo_progress_start "Downloading and extracting Nextcloud"
	codename=$(lsb_release -cs)
	if [[ $codename =~ ("stretch"|"xenial") ]]; then # TODO switch to PHP check instead
		echo_info "Switching to Nextcloud 15 due to an outdated version of PHP set by the OS"
		version="nextcloud-$(curl -s https://nextcloud.com/changelog/ | grep -A5 '"latest15"' | grep 'id=' | cut -d'"' -f2 | sed 's/-/./g')"
	else
		version=latest
	fi

	# TODO switch to tar.bz2 and curl?
	wget -q https://download.nextcloud.com/server/releases/${version}.zip -O /tmp/nextcloud.zip >> $log 2>&1
	unzip /tmp/nextcloud.zip -dq /srv >> $log 2>&1
	rm -rf /tmp/nextcloud.zip
	echo_progress_done "Downloaded"

	#Set permissions as per nextcloud
	echo_progress_start "Configuring permissions"
	ocpath='/srv/nextcloud'
	htuser='www-data'
	htgroup='www-data'
	rootuser='root'

	mkdir -p $ocpath/{data,assets,updater}
	find ${ocpath}/ -type f -print0 | xargs -0 chmod 0640
	find ${ocpath}/ -type d -print0 | xargs -0 chmod 0750
	chown -R ${rootuser}:${htgroup} ${ocpath}/
	chown -R ${htuser}:${htgroup} ${ocpath}/{apps,assets,config,data,themes,updater}
	chmod +x ${ocpath}/occ
	if [ -f ${ocpath}/.htaccess ]; then
		chmod 0644 ${ocpath}/.htaccess
		chown ${rootuser}:${htgroup} ${ocpath}/.htaccess
	fi
	if [ -f ${ocpath}/data/.htaccess ]; then
		chmod 0644 ${ocpath}/data/.htaccess
		chown ${rootuser}:${htgroup} ${ocpath}/data/.htaccess
	fi
	echo_progress_done "Permissions set"

	# echo "Installing cron jobs"
	crontab -l -u $htuser > /tmp/newcron.txt
	echo "*/5  *  *  *  * php -f /var/www/nextcloud/" >> /tmp/newcron.txt
	crontab -u $htuser /tmp/newcron.txt
	rm /tmp/newcron.txt
}

function _nginx() {
	echo_progress_start "Configuting nginx and PHP"
	bash /etc/swizzin/scripts/nginx/nextcloud.sh
	systemctl reload nginx
	echo_progress_done "nginx and PHP setup"
}

function _bootstrap() {
	echo_progress_start "Configuring Nextcloud settings"

	_occ "maintenance:install --database 'mysql' --database-name 'nextcloud'  --database-user 'nextcloud' --database-pass '$nextcldMySqlPW' --admin-user '$masteruser' --admin-pass '$masterpass' "
	_occ "maintenance:mode --on"
	_occ "db:add-missing-indices"
	_occ "db:convert-filecache-bigint --no-interaction"

	i=1
	_occ "config:system:set trusted_domains $i --value='localhost'"
	((i++))
	ip=$(ip route get 1 | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p')
	_occ "config:system:set trusted_domains $i --value=$ip"
	((i++))
	_occ "config:system:set trusted_domains $i --value=$(hostname)"
	((i++))
	_occ "config:system:set trusted_domains $i --value=$(hostname)"
	for value in $(grep server_name /etc/nginx/sites-enabled/default | cut -d' ' -f 4 | cut -d\; -f 1); do
		if [[ $value != "_" ]]; then
			_occ "config:system:set trusted_domains $i --value=$value"
			((i++))
		fi
	done
	#All users but the master user

	_occ "maintenance:mode --off"
	echo_progress_done "Nextcloud configured"
}
restart_php_fpm

function _users() {
	for u in "${users[@]}"; do
		echo_progress_start "Adding $u to Nextcloud"
		OC_PASS=$(_get_user_password "$u")
		export OC_PASS
		#TODO decide what happens wih the stdout from this
		_occ "user:add --password-from-env --display-name=${u} --group='users' ${u}"
		unset OC_PASS
		echo_progress_done "$u added to nextcloud"
	done
}

# shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
# shellcheck source=sources/functions/nextcloud
. /etc/swizzin/sources/functions/nextcloud

masteruser=$(cut -d: -f1 < /root/.master.info)
masterpass=$(_get_user_password "$masteruser")

if [[ -n $1 ]]; then
	users=($1)
	_users
	exit 0
fi

_db_setup
_install
_nginx
_bootstrap
users=($(_get_user_names | sed "/^$masteruser\b/Id"))
_users
touch /install/.nextcloud.lock

echo_success "Nextcloud installed"
echo_info "Please log in using your master credentials."
