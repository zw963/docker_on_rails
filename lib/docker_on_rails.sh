#!/usr/bin/env bash

set +x

function __regexp_escape () {
    sed -e 's/[]\/$*.^|[]/\\&/g'
}

function __replace_escape () {
    sed -e 's/[\/&]/\\&/g'
}

function __replace_config_file () {
    # option 应该是包含 key 中的字符以及可能存在的空格, 等号.
    # 例如: config.consider_all_requests_local       = false 中,
    # options 应该是: 'config.consider_all_requests_local'
    # 但实际匹配结果为: 'config.consider_all_requests_local      = '
    local option="$(echo "$1" |__regexp_escape)"
    local value="$(echo "$2" |__replace_escape)"
    local config_file=$3

    sed -i.bak -e "s/\($option[         =]*\).*/\1$value/" "$config_file"
}

function RUN () {
    sleep 1
    docker exec -i ${docker_user+-u} $docker_user $__CONTAINER "$@"
}

function PSQL () {
    sleep 1
    docker exec ${docker_user+-u} $docker_user $__CONTAINER psql -c "$@"
}


function TOUCH () {
    # local dir=$(dirname $1)
    # RUN mkdir -p $dir
    docker exec -i $__CONTAINER truncate -s 1 $1
    docker exec -i $__CONTAINER sed -i "s/.*/${2-\n}/" $1
    docker exec -i $__CONTAINER chmod 0600 $1
}
function APPEND () {
    local content=$1
    local file=$2
    docker exec ${docker_user+-u} $docker_user $__CONTAINER sed -i "$ a $content" $file
}

function RESTART () {
    sleep 1.5
    docker restart $__CONTAINER
    docker logs $__CONTAINER
}

# 注意: 下面的模块, 必须放在 ENVS 的循环之前才有意义!
function __BUILD_NEW_SECRET () {
    local secret_file=/tmp/${__BASE_CONTAINER}/secret
    if [ -s $secret_file -a "$RAILS_ENV" != production ]; then
        export SECRET_KEY_BASE=$secrect_file
    else
        export SECRET_KEY_BASE=$(ruby -e "require 'securerandom'; puts SecureRandom.hex(64)")
    fi
}

if [ "$dockerized_app_debug_mode" == "true" ]; then
    __replace_config_file 'config.consider_all_requests_local' 'true' ./config/environments/production.rb
fi

set -e

# 另一种写法.
# ROOT=`dirname "$0"`
# ROOT=`cd "$ROOT/.." && pwd`

if [ -z "$RAILS_ENV" ]; then
    echo 'Need specify $RAILS_ENV first.'
    exit
fi

__PWD=$(pwd)
echo "$__PWD is as current working directory"
__ROOT=$(builtin cd "$__PWD/config/containers" &>/dev/null && pwd)
echo "Container ROOT is: ${__ROOT}"
__BUILD_SCRIPT_NAME=$(basename $1)
echo "Build scripts name is: ${__BUILD_SCRIPT_NAME}"

__DOCKERFILE=$__ROOT/$dockerfile
__ARGS=''

# 仅仅接受一个参数, 端口号/项目名称. (这里的 $2 是 build_?? 脚本的唯一参数.)
if [ "$2" ]; then
    # 如果参数指定的是端口.
    if [ "$2" -eq "$2" ] &>/dev/null; then
        __OUTER_EXPOSED_PORT=$1
    else
        __CONTAINER_NAME=$2
    fi
elif [ "$container_name" ]; then
    __CONTAINER_NAME=$container_name
else
    # 默认从脚本名中获取, 例如: build_pg_master, __CONTAINER_NAME 就是 pg_master
    __CONTAINER_NAME=$(basename $__BUILD_SCRIPT_NAME |cut -d'_' -f2-)
fi

if [ "$PROJECT_NAME" ]; then
    # 如果环境变量中有指定, 无论目录名是啥, 都使用该环境变量
    __NAME=$PROJECT_NAME
else
    # 默认为项目名, 例如: ershou_web
    __NAME=$(basename $__PWD)
fi

__NEW_NAME=$(echo $__NAME |tr '_' '-')
__NEW_CONTAINER_NAME=$(echo $__CONTAINER_NAME |tr '_' '-')
__BASE_CONTAINER=${__NEW_NAME}.${__NEW_CONTAINER_NAME}

__ENTRYPOINT="$__ROOT/../docker-entrypoint1.sh"
[ -f $__ENTRYPOINT ] && chmod +x $__ENTRYPOINT || true

__PACKAGE=${__NEW_NAME}/$(echo $dockerfile |cut -d'/' -f1)

__IMAGE_DIR="$(dirname `mktemp`)/$__PACKAGE"

__docker_build_command="docker build -f $__DOCKERFILE -t $__PACKAGE ."
echo '********************************************************************************'
echo $__docker_build_command
echo '********************************************************************************'
$__docker_build_command || exit

if ! __INNER_EXPOSED_PORTS=$(docker inspect --type image -f '{{.Config.ExposedPorts}}' $__PACKAGE |egrep -o '[0-9]+'); then
    echo "Does not export a port in your's Dockerfile ?"
    exit
fi
__DEFAULT_PORT=$(echo "$__INNER_EXPOSED_PORTS" |sort -n |head -n1)

# __ENVS=$(docker inspect -f '{{.Config.Env}}' ershou-web.app |egrep -o '[a-zA-Z_][a-zA-Z0-9_]*='|cut -d'=' -f1)
# 展开通过 \回车 方式编写的行, 找出环境变量.
# __DOCKERFILE_ENVS=$(cat $__DOCKERFILE |sed -e ':a' -e 'N' -e '$!ba' -e 's/\\\n/ /g'|grep '^ENV'|grep -o '[a-zA-Z_][a-zA-Z0-9_]*='|cut -d'=' -f1)

__DOCKERFILE_ENVS=($(docker inspect -f '{{.Config.Env}}' $__PACKAGE|cut -d'[' -f2 |cut -d']' -f1))

if [ "$dockerized_app_build_new_secret" == true ]; then
    __BUILD_NEW_SECRET
fi

# 注意: 这里仅仅接受通过 export 声明的变量.
for i in ${__DOCKERFILE_ENVS[@]}; do
    __ENV_KEY=${i%=*}

    if [ "$__ENV_KEY" == 'PATH' ]; then
        continue
    fi

    if [ "$__ENV_KEY" == 'LANG' ]; then
        continue
    fi

    __ENV_VALUE="$(eval "echo \$$__ENV_KEY")"

    # 表示覆盖了 Docker 中的变量, 而且覆盖后不为空.
    if [ "$i" != "$__ENV_KEY"="$__ENV_VALUE" ] && [ -n "$__ENV_VALUE" ]; then
        __ARGS="$__ARGS -e $__ENV_KEY"
    fi
done

case "${__DEFAULT_PORT}" in
    5432)
        __PING_COMMAND='pg_isready -q'
        # 如果打算在本地启动 app, 则复制一些 pg gem 所需的依赖到 /usr/local
        # TODO: 如果是 Mac, 这里的逻辑需要判断, 通过 brew 来安装 pg.

        # TODO: pg_config 这个还有问题, 安装时还是找不到.
        # if ! which pg_config &>/dev/null; then
        #     sudo cp -av $__ROOT/bin/pg_ext/client/* /usr/local && sudo ldconfig
        # fi
        ;;
    6379)
        # redis
        __PING_COMMAMD='redis-cli info'
        ;;
    3000)
        # app
        __SOCKET_FILE="/tmp/puma.${__CONTAINER_NAME}.${__NAME}.sock"
        ;;
    80)
        # nginx
        __PING_COMMAND='nginx -s reopen'

esac

# 这个变量用来决定是使用本地端口开放部署, 还是使用 docker 网络部署.
# 这个变量通常在部署时单独指定.
# 首先尝试建立 network, 例如:: ershou-web.my-app.network

# 如果是 app, 则尝试建立 network, 并将自己加入这个 network

if [ "$depend_on_services" ]; then
    # 如果声明了 depend_on_services, 表示这是一个 app.
    # 此时需要执行以下两个步骤:
    # 1. 创建一个 app 自己的 network
    __NETWORK=${__NEW_NAME}.network

    set +e
    docker network create $__NETWORK 2>/dev/null
    set -e

    for service in $depend_on_services; do
        status=$(docker inspect -f '{{.State.Status}}' $service)

        if [ "$status" != running ]; then
            echo "Depend service error: container $service not start"
            exit
        fi
    done

    # 如果服务都存在, 将所有这些服务加入当前 app 的网络.
    for service in $depend_on_services; do
        set +e
        docker network connect $__NETWORK $service
        set -e
    done
fi

# if [ $? == 0 -o $? == 1 ]; then
#     # 如果指定了 $container_name, 这通常是一个 public container,
#     if [ "$container_name" ]; then
#         set +e
#         # 此时建立一个这个 container 相关的 public network.
#         docker network create ${container_name}.network 2>/dev/null
#         set -e

#         # 并且, public container 加入这个 public network
#         __ARGS="$__ARGS --network=${container_name}.network"
#     else
#         __ARGS="$__ARGS --network=${__NEW_NAME}.network"
#     fi
# fi

# 设置 $container_run_as_daemon 为 false,  container 将不作为 daemon 启动.
# 默认作为 daemon 启动.
if [ "$container_run_as_daemon" != false ]; then
    __ARGS="$__ARGS -d"
fi

# 两个参数只能选其一
if [ "$run_only_once" == true ]; then
    __ARGS="$__ARGS --rm"
elif [ "$auto_restart" == true ]; then
    __ARGS="$__ARGS --restart=always"
fi

if [ "$container_name" ]; then
    unset __NEW_PORT
    __ARGS="$__ARGS -P"
elif [ "$__OUTER_EXPOSED_PORT" ]; then
    # 如果用户指定, 使用用户指定端口.
    __NEW_PORT=$__OUTER_EXPOSED_PORT
    __ARGS="$__ARGS -p 127.0.0.1:$__NEW_PORT:$__DEFAULT_PORT"
elif [ "$DEFAULT_PORT" ]; then
    # 否则使用 build 脚本中设定的默认端口
    __ARGS="$__ARGS -p 127.0.0.1:$DEFAULT_PORT:$DEFAULT_PORT"
else
    if [ "$container_named_as_numeric" == true -o "$CONTAINER_NAMED_AS_NUMERIC" == true ]; then
        # 当启动多个 container 时, 从 0 开始编号.
        set +e
        last_container=$(docker ps -a --format="table {{.Names}}"|egrep "${__BASE_CONTAINER}.[0-9]{2}$"|sort -V |tail -1|egrep -o '[0-9]{2}$')
        set -e
        if [ "$last_container" ]; then
            __NEW_PORT=$(printf "%02g" $(($(printf "%g" $last_container)+1)))
        else
            __NEW_PORT=$(printf "%02g" 1)
        fi
        # 暴露所有的内部端口, 外部使用随机端口即可, 避免冲突.
        __ARGS="$__ARGS -P"
    else
        # 自动查找下一个可用的端口.
        for __IPORT in $(echo "$__INNER_EXPOSED_PORTS" |sort -n -r); do
            __NEW_PORT=$__IPORT
            while (6<>/dev/tcp/127.0.0.1/${__NEW_PORT}) &>/dev/null; do
                __NEW_PORT=$(($__NEW_PORT+1))
            done
            __ARGS="$__ARGS -p 127.0.0.1:$__NEW_PORT:$__IPORT"
            # sed "s#<%= ENV.fetch('DATABASE_HOSTNAME', '127.0.0.1') %>#127.0.0.1#g"
        done
    fi
fi

__CONTAINER=${__BASE_CONTAINER}${__NEW_PORT+.}$__NEW_PORT

if [ "$data_volume" ]; then
    # 建立单独的数据卷或目录, 例如: ershou-web.pg.data
    __HOST_DATA_DIR=$(echo $data_volume |cut -d':' -f1)

    if [ "$__HOST_DATA_DIR" == "$data_volume" ]; then
        # 如果相等, 表示没有 :, 即: 应该使用 volume
        __DATA_VOLUME=${__CONTAINER}.data
        docker volume create --name $__DATA_VOLUME
        __ARGS="$__ARGS -v ${__DATA_VOLUME}:${data_volume}"
    else
        if [ ! -d $__HOST_DATA_DIR ]; then
            echo "Create data directory $__HOST_DATA_DIR first"!
            exit
        fi
        __GUEST_DATA_DIR=$(echo $data_volume |cut -d':' -f2)
        __ARGS="$__ARGS -v ${__HOST_DATA_DIR}:${__GUEST_DATA_DIR}"
    fi
fi

if [ "$log_volume" ]; then
    # 建立单独的日志卷: 例如: ershou-web.app.log
    __LOG_VOLUME=${__CONTAINER}.log
    docker volume create --name $__LOG_VOLUME
    __ARGS="$__ARGS -v ${__LOG_VOLUME}:${log_volume}"
fi

if [ "$dockerconfig" ]; then
    __ARGS="$__ARGS -v ${__ROOT}/${dockerconfig}"
    __config=$(echo $dockerconfig |cut -d':' -f2)
elif [ "$dockerconfigdir" ]; then
    __ARGS="$__ARGS -v ${__ROOT}/${dockerconfigdir}"
fi

if [ "$shared_volumes" ]; then
    # app 共享的文件所在的卷, 例如: public/assets, tmp/cache 等.
    __SHARED_VOLUME=${__BASE_CONTAINER}.shared
    docker volume create --name $__SHARED_VOLUME
    for __volume in $shared_volumes; do
        __ARGS="$__ARGS -v ${__SHARED_VOLUME}:${INSTALL_PATH}/$__volume"
    done
fi

# 设置 $only_build_container 为 true, 只 build,  但是不 run.
# 默认 build 并且 run.
if [ "$only_build_container" != true ]; then
    function __PING () {
        set +e
        docker logs -f $__CONTAINER &
        pid=$(ps -C "docker logs -f $__CONTAINER" -o pid= |tail -1)
        if [ "$__SOCKET_FILE" ]; then
            while ! docker exec ${docker_user+-u} $docker_user $__CONTAINER test -S $__SOCKET_FILE && ! docker exec $__CONTAINER test -w $__SOCKET_FILE; do
                # echo -n '.'
                sleep 1.5
            done
        elif [ "$__PING_COMMAND" ]; then
            while ! eval "docker exec ${docker_user+-u} $docker_user $__CONTAINER $__PING_COMMAND" 2>/dev/null; do
                # echo -n '.'
                sleep 1.5
            done
        fi
        kill -2 $pid
        set -e
    }

    # 注意, 仅仅传递 $__config 作为运行参数, 而不提供对应的命令, 需要 docker-entrypoint 支持的.
    # 参照 redis 的做法: 支持直接传入一个参数或 ???.conf 给 docker, docker 会将其赋给 redis-server
    # # first arg is `-f` or `--some-option`
    # # or first arg is `something.conf`
    # if [ "${1#-}" != "$1" ] || [ "${1%.conf}" != "$1" ]; then
    #     set -- redis-server "$@"
    # fi
    # exec "$@"

    __docker_run_command="docker run --name $__CONTAINER $__ARGS -e LOCAL_USER_ID=$(id -u $USER) $__PACKAGE $__config"
    echo '********************************************************************************'
    echo $__docker_run_command
    echo '********************************************************************************'
    $__docker_run_command || exit
    __PING

    HOSTIP=$(docker exec $__CONTAINER ip route show | awk '/default/ {print $3}')
    CONTAINER_LOCALNET_IP=$(docker exec $__CONTAINER ip route show |egrep -o 'src [0-9.]+' |egrep -o '[0-9.]+')
    docker ps -f "name=$__CONTAINER" --format 'table {{.ID}}:\t{{.Names}}\t{{.Command}}\t{{.Ports}}'

    # $__NETWORK 存在, 表示创建了 app 网络, 然后加入之.
    [ "$__NETWORK" ] && docker network connect $__NETWORK $__CONTAINER

    # 例如: pg-master 需要连接到 pgbouncer 的网络.
    # 这里的 connect_to_network 必须是已经存在的.
    # for i in ${connect_to_network[@]}; do
    #     docker network connect $i $__CONTAINER
    # done

    # function __append_or_replace () {
    #     local content=$1
    #     local file=$2
    #     local regexp="^\\s*$(echo "$content" |sed -e 's/[]\/$*.^|[]/\\&/g')\b"

    #     # unless expected config exist, otherwise append config to last line.
    #     if ! grep -qs $regexp $file; then
    #         echo "$content" >> $file
    #         echo "[0m[33mAppend \`$content' into $file[0m"
    #     else
    #         local replace="$(echo "$2" |replace_escape)"
    #     fi
    # }

    # 先这样解决, 确保可以正确访问网址, 稍后更改.
    # if [ "$HTTP_HOST" ]; then
    #     # __port=$(docker port $__CONTAINER |grep -o '0.0.0.0:[0-9]\{5\}' |cut -d':' -f2)
    #     # 如果 hosts 文件中存在纪录, 执行替换.
    #     if grep -qs -e "^[^#].*$HTTP_HOST" /etc/hosts; then
    #         sudo sed -i "s#[0-9.]* *$HTTP_HOST#$CONTAINER_LOCALNET_IP $HTTP_HOST#" /etc/hosts
    #         sudo sed -i "s#[0-9.]* *assets\.mymart\.com#$CONTAINER_LOCALNET_IP assets.mymart.com#" /etc/hosts
    #         sudo sed -i "s#[0-9.]* *action-cable\.mymart\.com#$CONTAINER_LOCALNET_IP action-cable.mymart.com#" /etc/hosts
    #     else
    #         sudo sed -i "1i$CONTAINER_LOCALNET_IP ${HTTP_HOST}\n$CONTAINER_LOCALNET_IP assets.mymart.com\n$CONTAINER_LOCALNET_IP action-cable.mymart.com" /etc/hosts
    #     fi
    # fi
fi

OUTER_EXPOSED_PORT=$__NEW_PORT
CONTAINER_NAME=$__CONTAINER
PROJECT_NAME=$__NAME

[ -f $__ENTRYPOINT ] && rm $__ENTRYPOINT || true

set +x
