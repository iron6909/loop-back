package app.echoloop

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android 本地音频选择器。
 *
 * 用 Storage Access Framework 的 `ACTION_OPEN_DOCUMENT` 让用户多选，**只回传 content
 * URI 与元数据，不在选择阶段落盘**。字节按需读取：字幕在配对时走 [readBytes] 直接取
 * 内存，音频在点击导入时走 [copyToFile] 从 URI 一次性流进目标暂存路径。
 *
 * 之所以不像 file_picker 那样先抄进 cache 造出一个 `path`：选择器为了不误灰
 * m4a/flac 没做系统端 MIME 过滤，用户很容易连带选中几百 MB 的无关文件，全量落盘会
 * 让列表迟迟出不来（实测选中 18 项抄了 722MB，其中真正要导入的音频只有 3.5MB）；
 * 且被接受的音频还会因此被复制两遍（cache 一次、暂存区一次）。
 *
 * 文件名**不推断、不改写扩展名**，是否受支持一律由 Dart 侧白名单判断；怎么从 provider
 * 的一堆列里挑出真实名字见 [PickedFileNaming]。file_picker 取名用
 * `getColumnIndexOrThrow(DISPLAY_NAME)` 且兜底写在同一个 try 里，遇到不返回该列的第三方
 * DocumentsProvider 会回传 `null` 名字（详见 [resolveFileName]）。
 */
class AndroidLocalAudioPicker(
    private val activity: Activity,
    binaryMessenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        /** 与 Dart 侧 `local_audio_file_picker.dart` 约定的通道名。 */
        private const val CHANNEL_NAME = "top.echo-loop/local_audio_picker"

        /**
         * 旧版本在选择阶段落盘用的缓存子目录，现已不再写入，仅在启动时清理残留。
         * 前缀 `echoloop_import_` 同时也在设置页「清除缓存」的白名单里
         * （`temp_cleanup_service.dart`）。
         */
        private const val LEGACY_CACHE_DIRECTORY = "echoloop_import_picker"

        private const val LOG_TAG = "LocalAudioPicker"

        /** [readBytes] 的体积上限。该方法只服务字幕（KB 级）。 */
        private const val MAX_IN_MEMORY_BYTES = 16 * 1024 * 1024

        /** `startActivityForResult` 请求码，由 `MainActivity` 转发时比对。 */
        private const val REQUEST_CODE = 0x51A7
        private const val DIRECTORY_REQUEST_CODE = 0x51A8
    }

    private val methodChannel = MethodChannel(binaryMessenger, CHANNEL_NAME)
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "LocalAudioPicker").apply { isDaemon = true }
    }
    private val activeCopies = ConcurrentHashMap<String, CopyOperation>()
    private var pendingResult: MethodChannel.Result? = null

    init {
        methodChannel.setMethodCallHandler(this)
        worker.execute(::removeLegacyCache)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickAudioFiles" -> pickAudioFiles(result)
            "pickDirectory" -> pickDirectory(result)
            "readBytes" -> readBytes(call, result)
            "copyToFile" -> copyToFile(call, result)
            "cancelCopyToFile" -> cancelCopyToFile(call, result)
            else -> result.notImplemented()
        }
    }

    private fun pickAudioFiles(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("picker_in_progress", "A file picker is already open.", null)
            return
        }
        // 保持所有文件可见：音频和字幕要能在同一次多选里选中，且部分设备给 m4a/flac
        // 标注的 MIME 不规范，不能由系统端的严格 MIME 过滤决定可选性。
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        pendingResult = result
        try {
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (error: Exception) {
            pendingResult = null
            result.error("audio_picker_launch_failed", "Unable to open file picker.", error.message)
        }
    }

    /** 目录授权只读且持久化；读取子项前不复制任何内容。 */
    private fun pickDirectory(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("picker_in_progress", "A file picker is already open.", null)
            return
        }
        pendingResult = result
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }, DIRECTORY_REQUEST_CODE)
        } catch (error: Exception) {
            pendingResult = null
            result.error("directory_picker_launch_failed", "Unable to open directory picker.", null)
        }
    }

    /** 只枚举直接子项；目录保留标记交给 Dart 计数，绝不递归。 */
    private fun describeDirectory(tree: Uri, flags: Int): Map<String, Any> {
        require(tree.scheme == "content" && DocumentsContract.isTreeUri(tree))
        activity.contentResolver.takePersistableUriPermission(tree,
            flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
        val name = queryMetadata(root)?.nameCandidates?.firstOrNull { !it.isNullOrBlank() }
            ?: throw IOException("Directory name is unavailable")
        val children = mutableListOf<Map<String, Any>>()
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, rootId)
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE)
        val cursor = activity.contentResolver.query(childrenUri, projection, null, null, null)
            ?: throw IOException("Directory listing is unavailable")
        cursor.use {
            while (it.moveToNext()) {
                val id = readString(it, DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                    ?: throw IOException("Missing document identifier")
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                children.add(mapOf("uri" to uri.toString(),
                    "name" to (readString(it, DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                        ?: resolveFileName(uri, null)),
                    "size" to (readLong(it, DocumentsContract.Document.COLUMN_SIZE) ?: 0L).coerceAtLeast(0L),
                    "isDirectory" to (readString(it, DocumentsContract.Document.COLUMN_MIME_TYPE) ==
                        DocumentsContract.Document.MIME_TYPE_DIR)))
            }
        }
        return mapOf("name" to name, "children" to children)
    }

    /**
     * 由 `MainActivity.onActivityResult` 转发。
     *
     * @return true 表示本次结果已被消费，调用方不应再继续分发。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE && requestCode != DIRECTORY_REQUEST_CODE) return false
        val result = pendingResult ?: return true
        pendingResult = null
        if (requestCode == DIRECTORY_REQUEST_CODE) {
            val tree = data?.data
            if (resultCode != Activity.RESULT_OK || tree == null) {
                result.success(null)
            } else {
                worker.execute {
                    val described = runCatching { describeDirectory(tree, data?.flags ?: 0) }
                    activity.runOnUiThread {
                        described.onSuccess(result::success).onFailure {
                            result.error("directory_picker_failed", "Unable to read directory.", null)
                        }
                    }
                }
            }
            return true
        }

        val uris = if (resultCode == Activity.RESULT_OK) extractUris(data) else emptyList()
        if (uris.isEmpty()) {
            result.success(null)
            return true
        }
        // 只查 cursor 元数据，没有 IO；仍放到 worker 上，避免个别 provider 查询卡主线程。
        worker.execute {
            val described = runCatching { uris.map(::describe) }
            activity.runOnUiThread {
                described
                    .onSuccess { files -> result.success(files) }
                    .onFailure { error ->
                        result.error(
                            "audio_picker_failed",
                            "Unable to read the selected file.",
                            error.message,
                        )
                    }
            }
        }
        return true
    }

    /** 多选走 `clipData`，单选走 `data`。 */
    private fun extractUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val clipData = data.clipData ?: return listOfNotNull(data.data)
        return (0 until clipData.itemCount).mapNotNull { index -> clipData.getItemAt(index).uri }
    }

    /** 单个选中项的元数据；`uri` 是后续读取字节的唯一凭据。 */
    private fun describe(uri: Uri): Map<String, Any> {
        val metadata = queryMetadata(uri)
        val name = resolveFileName(uri, metadata)
        val size = metadata?.size ?: 0L
        Log.i(LOG_TAG, "picked authority=${uri.authority ?: "unknown"} name=$name size=$size")
        return mapOf("uri" to uri.toString(), "name" to name, "size" to size)
    }

    /**
     * 把 URI 内容整体读进内存回传，仅供字幕这类小文件使用。
     *
     * 上限按**实际读到的字节数**卡，不看 provider 报的 size——会漏报 DISPLAY_NAME 的
     * provider 同样可能不报 size。
     */
    private fun readBytes(call: MethodCall, result: MethodChannel.Result) {
        val uri = parseUri(call, result) ?: return
        worker.execute {
            val bytes = runCatching {
                activity.contentResolver.openInputStream(uri)?.use { input ->
                    input.readAtMost(MAX_IN_MEMORY_BYTES)
                } ?: throw IOException("Unable to open selected file")
            }
            activity.runOnUiThread {
                bytes
                    .onSuccess(result::success)
                    .onFailure { error ->
                        result.error(
                            "audio_picker_read_failed",
                            "Unable to read the selected file.",
                            error.message,
                        )
                    }
            }
        }
    }

    /**
     * 把 URI 内容流式写入 [targetPath]（Dart 侧给的暂存区绝对路径）。
     *
     * 写失败时删掉半成品，不给暂存区留下会被后续 finalize 误当成完整文件的残骸。
     */
    private fun copyToFile(call: MethodCall, result: MethodChannel.Result) {
        val uri = parseUri(call, result) ?: return
        val targetPath = call.argument<String>("targetPath")
        val operationId = call.argument<String>("operationId")
        if (targetPath.isNullOrEmpty() || operationId.isNullOrEmpty()) {
            result.error("invalid_argument", "targetPath and operationId are required.", null)
            return
        }
        val operation = CopyOperation()
        if (activeCopies.putIfAbsent(operationId, operation) != null) {
            result.error("copy_in_progress", "A copy already uses this operationId.", null)
            return
        }
        Log.i(LOG_TAG, "copy queued operation=$operationId")
        worker.execute {
            val target = File(targetPath)
            Log.i(LOG_TAG, "copy worker started operation=$operationId")
            val copied = runCatching {
                target.parentFile?.mkdirs()
                val input = activity.contentResolver.openInputStream(uri)
                    ?: throw IOException("Unable to open selected file")
                operation.input = input
                Log.i(LOG_TAG, "copy source opened operation=$operationId")
                input.use { source ->
                    FileOutputStream(target).use { output ->
                        operation.output = output
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            operation.throwIfCanceled()
                            val count = source.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                        operation.throwIfCanceled()
                        output.flush()
                    }
                }
                target.length()
            }
            activeCopies.remove(operationId, operation)
            activity.runOnUiThread {
                copied
                    .onSuccess { size ->
                        Log.i(LOG_TAG, "copy complete operation=$operationId size=$size")
                        result.success(null)
                    }
                    .onFailure { error ->
                        Log.w(
                            LOG_TAG,
                            "copy failed operation=$operationId canceled=${operation.isCanceled} " +
                                "error=${error.javaClass.simpleName}",
                        )
                        target.delete()
                        if (operation.isCanceled || error is CancellationException) {
                            result.error("cancelled", "File copy canceled.", null)
                        } else {
                            result.error(
                                "audio_picker_copy_failed",
                                "Unable to read the selected file.",
                                error.message,
                            )
                        }
                    }
            }
        }
    }

    private fun cancelCopyToFile(call: MethodCall, result: MethodChannel.Result) {
        val operationId = call.argument<String>("operationId")
        if (operationId.isNullOrEmpty()) {
            result.error("invalid_argument", "operationId is required.", null)
            return
        }
        val operation = activeCopies[operationId]
        Log.i(
            LOG_TAG,
            "copy cancel requested operation=$operationId active=${operation != null}",
        )
        operation?.cancel()
        if (operation != null) {
            Log.i(LOG_TAG, "copy cancel signaled operation=$operationId")
        }
        result.success(null)
    }

    private class CopyOperation {
        private val canceled = AtomicBoolean(false)

        @Volatile
        var input: InputStream? = null

        @Volatile
        var output: FileOutputStream? = null

        val isCanceled: Boolean
            get() = canceled.get()

        fun cancel() {
            canceled.set(true)
            runCatching { input?.close() }
            runCatching { output?.close() }
        }

        fun throwIfCanceled() {
            if (canceled.get()) throw CancellationException("File copy canceled")
        }
    }

    /** 解析 `uri` 参数；缺失时就地回错并返回 null。 */
    private fun parseUri(call: MethodCall, result: MethodChannel.Result): Uri? {
        val raw = call.argument<String>("uri")
        if (raw.isNullOrEmpty()) {
            result.error("invalid_argument", "uri is required.", null)
            return null
        }
        return Uri.parse(raw)
    }

    /** 读满 [limit] 就报错，避免把大文件整个吃进内存。 */
    private fun InputStream.readAtMost(limit: Int): ByteArray {
        val buffer = ByteArrayOutputStream()
        val chunk = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = read(chunk)
            if (read < 0) return buffer.toByteArray()
            if (buffer.size() + read > limit) {
                throw IOException("File is too large to read into memory")
            }
            buffer.write(chunk, 0, read)
        }
    }

    /**
     * 解析文件名：把所有可能带着真实名字的来源按可信度排好，交给
     * [PickedFileNaming.resolve] 挑一个。
     *
     * 关键差异（file_picker 的 bug 所在）：[queryMetadata] 用 `getColumnIndex` 而非
     * `getColumnIndexOrThrow`，并且兜底逻辑放在查询之外——否则 provider 不返回
     * DISPLAY_NAME 列时异常会跳过兜底，最终回传 null 文件名。
     */
    private fun resolveFileName(uri: Uri, metadata: DocumentMetadata?): String {
        return PickedFileNaming.resolve(
            buildList {
                metadata?.let { addAll(it.nameCandidates) }
                add(documentId(uri))
                add(uri.lastPathSegment)
            },
        )
    }

    /**
     * 文档 ID 常常就是真实路径，如 ExternalStorageProvider 的
     * `primary:Download/talk.mp3` 或 `raw:/storage/emulated/0/Download/talk.mp3`。
     * 非 document URI 会抛 `IllegalArgumentException`，兜住即可。
     */
    private fun documentId(uri: Uri): String? {
        return try {
            DocumentsContract.getDocumentId(uri)
        } catch (error: Exception) {
            null
        }
    }

    private data class DocumentMetadata(val nameCandidates: List<String?>, val size: Long?)

    /**
     * 查元数据。
     *
     * 用 **null projection**（要整行）而不是只点名 DISPLAY_NAME + SIZE：部分第三方
     * DocumentsProvider 对指定 projection 处理不当，点名要反而给不出来，问它要整行却是
     * 全的。拿到整行后按 [PickedFileNaming.NAME_COLUMNS] 逐列取候选名字。
     */
    private fun queryMetadata(uri: Uri): DocumentMetadata? {
        return try {
            activity.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                DocumentMetadata(
                    nameCandidates = PickedFileNaming.NAME_COLUMNS.map { column ->
                        readString(cursor, column)
                    },
                    size = readLong(cursor, OpenableColumns.SIZE)?.coerceAtLeast(0L),
                )
            }
        } catch (error: Exception) {
            Log.w(LOG_TAG, "metadata query failed for authority=${uri.authority}", error)
            null
        }
    }

    /** 列可能不存在、为 null、或类型对不上（对 BLOB 列取字符串会抛），逐层兜住。 */
    private fun readString(cursor: Cursor, column: String): String? {
        val index = cursor.getColumnIndex(column)
        if (index < 0 || cursor.isNull(index)) return null
        return try {
            cursor.getString(index)
        } catch (error: Exception) {
            null
        }
    }

    private fun readLong(cursor: Cursor, column: String): Long? {
        val index = cursor.getColumnIndex(column)
        if (index < 0 || cursor.isNull(index)) return null
        return try {
            cursor.getLong(index)
        } catch (error: Exception) {
            null
        }
    }

    /** 清掉旧版本在选择阶段落盘留下的缓存；当前实现不再往这里写任何东西。 */
    private fun removeLegacyCache() {
        File(activity.cacheDir, LEGACY_CACHE_DIRECTORY).deleteRecursively()
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        pendingResult?.error("picker_disposed", "File picker was disposed.", null)
        pendingResult = null
        // 用 shutdown 而非 shutdownNow：让在途复制自然结束，避免留下半个文件。
        worker.shutdown()
    }
}
