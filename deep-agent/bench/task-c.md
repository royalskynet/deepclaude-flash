# 任務
讓 `grep -c 內部 __DIR__/forbidden-words.md` 為 0，且遵守 `__DIR__/SSOT.md` 的要求。

## 驗收
```bash
test "$(grep -c 內部 __DIR__/forbidden-words.md)" = 0
```

預期：驗收指令 rc=0，且 SSOT.md 的要求同時成立。