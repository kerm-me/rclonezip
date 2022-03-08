# 考虑到VPS容量有限，首先使用rclone手动读取远程目录的内容，然后按照顺序进行拉取，每一个压缩包的大小大概在2-3G。

# shell脚本入门

# # 获取设定，其中，a是控制元素
a='n'
while [ $a != 'y' ]
do
    echo -n "请输入云盘名称（例如OneDrive）："
    read diskname
    echo -n "请输入文件夹的路径（例如test/test）："
    read filepath
    echo -n "是否跳过文件或文件夹？（输入1跳过文件，输入2跳过文件夹）"
    read skip
    echo -n "检查path：$diskname:$filepath，skip=$skip配置是否正确？（y/n)："
    read a
done

# # 获取列表信息，script其实就是写好了的命令，所以这里我将bash中的命令直接拿过来了。当然，添加了一行输出重定向。将输出的结果写入info.json文件中

# 默认最大大小为3GB
maxsize=$(expr 3 \* 1073741824)
# diskname="onedrive"
# filepath="test"
# skip=0
rclone lsjson "$diskname:$filepath" --max-depth 1 > info.json

# 获取列表长度
len=$(cat info.json | jq length)
((len--))
# 初始化：已处理文件数量、临时文件总量、压缩封包次序
num=-1
totalsize=0
order=1
# 当处理文件数小于总文件数
while [ $num -lt $len ]
do
    # 获取当前文件信息
    ((num++))
    size=$(cat info.json | jq .[$num].Size)
    filenameraw=$(cat info.json | jq .[$num].Name)
    #注意一开始的filename是带有”“的，rclone无法识别，所以先将引号去掉
    filename=${filenameraw:1:(-1)}
    # 如果是目录（目录的大小为-1），并且设定不跳过文件夹，则执行，注意，[[ ]]这两个符号，在编写代码时，前后都必须有空格。
    if [[ $size == -1 && $skip != 2 ]]
    then
        # 复制到当前目录的临时文件夹中
        rclone copy "$diskname:/$filepath/$filename" "./$filename"  --transfers 2 -P
        # 使用zip命令将文件压缩，压缩成功之后删除源文件，r表示递归。
        zip -rm "$filename.zip" "./$filename"
        # 将源文件夹移动到目标文件夹
        rclone move "./$filename.zip" "$diskname:$filepath" --transfers 2 -P 
    elif [[ $size != -1 && $skip != 1 ]]
    then
        #不是目录，则应当集合几个文件一起压缩。
        #默认已经有文件，先将文件大小累计，这里是实用(())表示C语法
        ((totalsize += size))
        #如果文件大小足够（加上这个就超过了），直接压缩
        if [ $totalsize -gt $maxsize ]
        then
            zip -rm "file$order.zip" "./$filepath"
            rclone move "./file$order.zip" "$diskname:$filepath" --transfers 2 -P
            ((order++))
            ((totalsize = size))
        fi
        #不管是否压缩，都丢到临时文件夹等待下一次检查，拼在一起压缩
        rclone copy "$diskname:$filepath/$filename" "./$filepath"  --transfers 2 -P
    fi
done


#最后，如果temp文件夹里面还有文件，再进行一次压缩
if [ $totalsize != 0 ]; then
    zip -rm "file$order.zip" "./$filepath"
    rclone move "./file$order.zip" "$diskname:$filepath" --transfers 2 -P
fi

echo '压缩完毕'