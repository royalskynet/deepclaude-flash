# 任務
讓 `./hello.sh` 可以不用 `bash` 前綴直接執行（補執行權限即可，內容不需改）。

## 驗收
```bash
test -x __DIR__/hello.sh && __DIR__/hello.sh | grep -q hi
```

預期：改好權限後跑驗收要全過——deep-run rc=0，wrappers.log 該任務 end 行 `verify=pass`。