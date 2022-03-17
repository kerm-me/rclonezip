#!/bin/bash
# 考虑到VPS容量有限，首先使用rclone手动读取远程目录的内容，然后按照顺序进行拉取，每一个压缩包的大小大概在2-3G。

# 获取设定，其中，a是控制元素，大写表示这里全部都是全局变量
function getinfo() {
    a='n'
    while [[ $a != 'y' ]]; do
        echo -n "请输入云盘名称（默认为onedrive）："
        read DISKNAME
        echo -n "请输入文件夹的路径（默认为path）："
        read FILEPATH
        echo -n "是否跳过文件或文件夹？（输入1跳过文件，输入2跳过文件夹，默认为零）"
        read SKIP
        echo -n '设置最大压缩包大小（默认3G）：'
        read MAXZIP

        # 提供默认值：
        if [[ -z "${DISKNAME}" ]]; then
            DISKNAME=onedrive
        fi
        if [[ -z "${FILEPATH}" ]]; then
            FILEPATH=path
        fi
        if [[ -z "${SKIP}" ]]; then
            SKIP=0
        fi
        # 默认最大大小为3GB
        if [[ -z "${MAXZIP}" ]]; then
            MAXZIP=3
        fi
        echo -n "检查路径：$DISKNAME:$FILEPATH，SKIP=$SKIP，max=${MAXZIP}G，配置是否正确？（y/n)："
        read a
    done
    MAXZIP=$(expr ${MAXZIP} \* 1073741824)
}

# 函数主体部分。
function upload() {
    # 传参
    local filepath="$1"
    echo "正在压缩${filepath}"
    #获取列表信息，script其实就是写好了的命令，所以这里我将bash中的命令直接拿过来了。当然，添加了一行输出重定向。将输出的结果写入info.json文件中
    #注意：每一个递归进程都需要一个unique的json文件。否则有可能导致配置文件互相冲突？
    #注意：如果路径中包含/字符，将导致错误结果，这里 /代替换字符/替换字符 用来替换/ 并且，\/使用反斜杠进行转义
    #https://www.cnblogs.com/wangym/articles/9121622.htmlecho ${string/23/bb}   //abc1bb42341  替换一次    
    #echo ${string/#abc/bb} //bb12342341   #以什么开头来匹配，根php中的^有点像    
    #echo ${string//23/bb}  //abc1bb4bb41  双斜杠替换所有匹配    
    #echo ${string/%41/bb}  //abc123423bb  %以什么结尾来匹配，根php中的$有点像   
    rclone lsjson "$DISKNAME:$filepath" --max-depth 1 > "${filepath//\//_}".json
    # 获取列表长度，并减一（从零开始）
    local len=$(cat "${filepath//\//_}".json | jq length)
    ((len--))
    # 初始化：已处理文件数量、临时文件总量、压缩封包次序
    local num=-1
    local totalsize=0
    local order=1
    # 当处理文件数小于总文件数
    while [[ $num -lt $len ]]; do
        # 获取当前文件信息
        ((num++))
        local size=$(cat "${filepath//\//_}".json | jq .[$num].Size)
        local filenameraw=$(cat "${filepath//\//_}".json | jq .[$num].Name)
        #注意一开始的filename是带有”“的，rclone无法识别，所以先将引号去掉
        local filename=${filenameraw:1:(-1)}
        # 如果是目录（目录的大小为-1），并且设定不跳过文件夹，则执行，注意，[[ ]]这两个符号，在编写代码时，前后都必须有空格。
        if [[ $size == -1 && $SKIP != 2 ]]; then
            echo "检测到目录$filepath $filename"
            # 加一行判断。如果这个文件夹比较大，就先不压缩，递归到里面去压缩完在出来。注意这里为了防止path中含有空格，进行了非常多的操作。
            local tempsize=$(rclone size $DISKNAME:"/$filepath"/"$filename" --json | jq .bytes)
            echo $tempsize
            if [[ $tempsize -gt $MAXZIP ]]; then
                upload "$filepath/$filename"
            # 如果比较小，直接压缩整个文件夹。
            elif [[ $tempsize != 0 ]]; then
                # 复制到当前目录的临时文件夹中
                rclone copy "$DISKNAME:/$filepath/$filename" "./$filename" --transfers 2 -P
                # 使用zip命令将文件压缩，压缩成功之后删除源文件，r表示递归。
                zip -rm "$filename.zip" "./$filename"
                # 将源文件夹移动到目标文件夹
                rclone move "./$filename.zip" "$DISKNAME:$filepath" --transfers 2 -P
            else
                echo "检测到空文件夹，rclone可能出现问题，请查验文件夹 $DISKNAME:/$filepath/$filename是否为空" >> log.txt
            fi
        elif [[ $size != -1 && $SKIP != 1 ]]; then
            #不是目录，则应当集合几个文件一起压缩。
            #默认已经有文件，先将文件大小累计，这里是实用(())表示C语法
            ((totalsize += size))
            #如果文件大小足够（加上这个就超过了），直接压缩
            if [ $totalsize -gt $MAXZIP ]; then
                zip -rm "file$order.zip" "./$filepath"
                rclone move "./file$order.zip" "$DISKNAME:$filepath" --transfers 2 -P
                ((order++))
                ((totalsize = size))
            fi
            #不管是否压缩，都丢到临时文件夹等待下一次检查，拼在一起压缩
            # 注意：为了避免二次压缩，这里不压缩拓展名为zip的文件。
            # 无需避免二次压缩，由于本来就是对原有list的遍历
            rclone copy "$DISKNAME:$filepath/$filename" "./$filepath" --transfers 2 -P
        fi
    done
    #最后，如果temp文件夹里面还有文件，再进行一次压缩，注意临时文件夹也要unique
    if [ $totalsize != 0 ]; then
        zip -rm "file$order.zip" "./$filepath"
        rclone move "./file$order.zip" "$DISKNAME:$filepath" --transfers 2 -P
    fi
    #最后的最后，清理文件，输出结果信息
    rm "${filepath//\//_}".json
    echo "${filepath}压缩完毕"
}

# 程序入口
getinfo 
upload "${FILEPATH}"
echo '全部压缩完毕'
exit 0
