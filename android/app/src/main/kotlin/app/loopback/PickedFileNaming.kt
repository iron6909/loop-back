package app.echoloop

/**
 * 从 DocumentsProvider 给的一堆候选里挑出选中文件的真实文件名。
 *
 * 拆成不依赖 Android 框架的纯逻辑，好用 JVM 单测覆盖各种畸形 provider 的回传
 * （见 `PickedFileNamingTest`）——真机上这些分支很难复现。
 *
 * 为什么需要「一堆候选」而不是只读 `DISPLAY_NAME`：SAF 契约要求 `CATEGORY_OPENABLE`
 * 的 provider 必须提供该列，但第三方实现（部分文件管理器、网盘 App）会回传 null。
 * 此时文件其实有正常的带后缀的名字，只是躺在别的列里——`_data` 是完整路径、
 * 文档 ID 常常形如 `primary:Download/talk.mp3`。挑名字的规则因此是
 * **优先取带扩展名的候选**，而不是死守第一个非空值：扩展名是 Dart 白名单判定
 * 「能不能导入」的唯一依据，丢了扩展名等于让一个正常音频被静默拒掉。
 *
 * 这里**不做任何格式推断**：不看 MIME、不看文件头、不改写已有扩展名。
 */
object PickedFileNaming {
    /**
     * 按可信度排序的候选列名。`_display_name` 是契约要求的正解，`_data` 是它缺失时的
     * 补位（完整路径，取 basename 后同样带扩展名）。
     *
     * 用字面量而非 `MediaStore.MediaColumns` 常量：`_data` 已废弃，引用常量会带来无谓
     * 的 deprecation 噪音，而列名本身是稳定的字符串协议。
     */
    val NAME_COLUMNS = listOf("_display_name", "_data")

    /** provider 什么都给不出时的最终兜底名，保证回传给 Dart 的名字非空。 */
    private const val FALLBACK_NAME = "selected"

    /** 扩展名长度上限，避免把 `talk.2026-08-02` 这类后缀当成扩展名。 */
    private const val MAX_EXTENSION_LENGTH = 10

    /**
     * 从 [candidates] 里挑一个文件名，按「带扩展名的第一个 → 非空的第一个 → 兜底名」。
     *
     * 每个候选都会先规整（取 basename、去空字符、去首尾空白），所以传完整路径、
     * 传 `primary:Download/talk.mp3` 这种文档 ID 都可以。
     */
    fun resolve(candidates: List<String?>): String {
        val normalized = candidates.mapNotNull(::sanitize)
        return normalized.firstOrNull(::hasExtension)
            ?: normalized.firstOrNull()
            ?: FALLBACK_NAME
    }

    /**
     * 取 basename 并剥掉空字符，防止文件名把内容写出目标目录。
     *
     * @return 规整后的名字；没有有效内容时返回 null。
     */
    private fun sanitize(name: String?): String? {
        val normalized = name
            ?.substringAfterLast('/')
            ?.substringAfterLast('\\')
            ?.replace('\u0000', '_')
            ?.trim()
            .orEmpty()
        return normalized.ifEmpty { null }
    }

    /** 点号必须在中间，且后缀是不太长的字母数字，否则不算扩展名。 */
    private fun hasExtension(name: String): Boolean {
        val index = name.lastIndexOf('.')
        if (index <= 0 || index == name.length - 1) return false
        val extension = name.substring(index + 1)
        return extension.length <= MAX_EXTENSION_LENGTH && extension.all(Char::isLetterOrDigit)
    }
}
