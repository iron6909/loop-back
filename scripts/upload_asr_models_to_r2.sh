#!/usr/bin/env bash
set -euo pipefail

# 从 HuggingFace 镜像下载 whisper 模型文件，校验 SHA256，上传到 R2。
# 支持断点续传：自动跳过 R2 上已存在且大小匹配的文件。
#
# 已退役：ASR 三档模型与共享 VAD 改由 App 直接从公开来源逐文件安装
# （见 lib/services/asr/asr_model_catalog.dart），不再经 EchoLoop R2 分发。
# 本脚本仅保留为上游 revision 与文件摘要的历史核对依据，不要用它作为发布流程。
#
# 用法:
#   scripts/upload_asr_models_to_r2.sh
#
# 环境变量（保密，在 ~/.zshrc 中配置）:
#   R2_ENDPOINT                 S3-compatible endpoint URL
#   R2_ACCESS_KEY_ID_PUBLIC     R2 API token access key ID (public bucket)
#   R2_SECRET_ACCESS_KEY_PUBLIC R2 API token secret access key (public bucket)

: "${R2_ENDPOINT:?Set R2_ENDPOINT}"
: "${R2_ACCESS_KEY_ID_PUBLIC:?Set R2_ACCESS_KEY_ID_PUBLIC}"
: "${R2_SECRET_ACCESS_KEY_PUBLIC:?Set R2_SECRET_ACCESS_KEY_PUBLIC}"

R2_BUCKET="public"
HF_MIRROR="https://hf-mirror.com"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo "$(date +%H:%M:%S) $*"; }
fail() { log "✗ $*"; exit 1; }

# 校验 SHA256
verify_sha256() {
  local file="$1" expected="$2"
  local actual
  actual=$(shasum -a 256 "$file" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    fail "SHA256 不匹配: $file\n  期望: $expected\n  实际: $actual"
  fi
}

# 检查 R2 上文件是否已存在且大小匹配
r2_file_exists() {
  local r2_key="$1" expected_size="$2"
  local result
  result=$(AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID_PUBLIC" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY_PUBLIC" \
    aws s3api head-object \
      --bucket "$R2_BUCKET" \
      --key "$r2_key" \
      --endpoint-url "$R2_ENDPOINT" 2>/dev/null) || return 1

  local remote_size
  remote_size=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['ContentLength'])" 2>/dev/null)
  [[ "$remote_size" == "$expected_size" ]]
}

# 模型定义: model_id|hf_repo|commit|filename:sha256,filename:sha256,...
MODELS=(
  "whisper-tiny-en-int8|csukuangfj/sherpa-onnx-whisper-tiny.en|d026532c022fa99fd789d6b32446a1df7b6bfc43|tiny.en-encoder.int8.onnx:0ce578b827c94a961aacb8fa14b02f096504b337e5c94be37c36238cbe3e8bc6,tiny.en-decoder.int8.onnx:06c0e6ff6348d427e51839219d1c886c18cfdf411e629e33f5e1679bff9c1527,tiny.en-tokens.txt:306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930"
  "whisper-base-en-int8|csukuangfj/sherpa-onnx-whisper-base.en|59eea950fc76df2453efb57e6c0fd334548e8ffe|base.en-encoder.int8.onnx:ef6b936f4c9b1d90a3b68634b60c4ed8576b26172b33c2535ec0e933c9edb823,base.en-decoder.int8.onnx:f7162ad6db2dbef16cfaeaa7f945b9d7dd9c1b8d472f6aca82f2273d185e4d41,base.en-tokens.txt:306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930"
  "whisper-small-en-int8|csukuangfj/sherpa-onnx-whisper-small.en|d9533f69affd85061aee349af7fea5cb2996dbbe|small.en-encoder.int8.onnx:8bdac288f369aa94ee2194059238c465ed82ea9d47ee8fa4a8c0a891873e462f,small.en-decoder.int8.onnx:710ccf890e10f3faa15f51ec346081a2723c9f3adb6e4da81c6573a5a6f877fb,small.en-tokens.txt:306cd27f03c1a714eca7108e03d66b7dc042abe8c258b44c199a7ed9838dd930"
)

for entry in "${MODELS[@]}"; do
  IFS='|' read -r model_id hf_repo commit files_csv <<< "$entry"
  IFS=',' read -ra file_specs <<< "$files_csv"

  log "📦 $model_id"

  for spec in "${file_specs[@]}"; do
    IFS=':' read -r filename expected_sha <<< "$spec"
    r2_key="model/$model_id/$filename"
    url="$HF_MIRROR/$hf_repo/resolve/$commit/$filename"
    local_path="$TMP_DIR/$filename"

    # 下载到本地获取预期大小（用 HEAD 请求）
    expected_size=$(curl -fsSLI "$url" | grep -i content-length | tail -1 | tr -dc '0-9')

    # 检查 R2 是否已有且大小匹配
    if r2_file_exists "$r2_key" "$expected_size"; then
      log "  ⏭ $filename 已存在，跳过"
      continue
    fi

    # 下载
    log "  ↓ 下载 $filename ..."
    if ! curl -fSL --progress-bar -o "$local_path" "$url"; then
      log "  ✗ 下载失败: $filename"
      rm -f "$local_path"
      continue
    fi

    # 校验
    log "  🔒 校验 SHA256 ..."
    if ! verify_sha256 "$local_path" "$expected_sha"; then
      log "  ✗ 校验失败，删除: $filename"
      rm -f "$local_path"
      continue
    fi
    log "    ✓ SHA256 校验通过"

    # 上传
    log "  ↑ 上传 → s3://${R2_BUCKET}/${r2_key}"
    if ! AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID_PUBLIC" \
      AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY_PUBLIC" \
      aws s3 cp "$local_path" "s3://${R2_BUCKET}/${r2_key}" \
        --endpoint-url "$R2_ENDPOINT" \
        --no-progress; then
      log "  ✗ 上传失败: $filename"
    fi

    rm -f "$local_path"
  done
  log "  ✓ $model_id 完成"
done

log "✅ 全部完成"
