package app.echoloop

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [PickedFileNaming] 的单测。
 *
 * 覆盖重点是「DISPLAY_NAME 缺失但文件其实有正常名字」这一类畸形 provider 的回传——
 * 真机上要碰到特定第三方文件管理器才能复现，只能靠单测守住。
 */
class PickedFileNamingTest {
    @Test
    fun `优先使用 DISPLAY_NAME`() {
        val name = PickedFileNaming.resolve(
            listOf("talk.mp3", "/storage/emulated/0/Download/other.mp3"),
        )

        assertEquals("talk.mp3", name)
    }

    @Test
    fun `DISPLAY_NAME 为 null 时退到 _data 的 basename`() {
        // 这就是 file_picker 直接崩掉的场景：文件本身有正常的带后缀名字。
        val name = PickedFileNaming.resolve(
            listOf(null, "/storage/emulated/0/Download/talk.mp3"),
        )

        assertEquals("talk.mp3", name)
    }

    @Test
    fun `所有列都缺失时退到文档 ID 里的路径`() {
        val name = PickedFileNaming.resolve(
            listOf(null, null, "primary:Download/talk.mp3", "primary%3ADownload"),
        )

        assertEquals("talk.mp3", name)
    }

    @Test
    fun `raw 形式的文档 ID 同样能取到名字`() {
        val name = PickedFileNaming.resolve(
            listOf(null, null, "raw:/storage/emulated/0/Music/talk.m4a"),
        )

        assertEquals("talk.m4a", name)
    }

    @Test
    fun `跳过没有扩展名的候选，优先取带扩展名的`() {
        // 丢了扩展名的名字会被 Dart 白名单静默拒掉，所以不能只取第一个非空值。
        val name = PickedFileNaming.resolve(listOf(null, "Talk", "1000000123.mp3"))

        assertEquals("1000000123.mp3", name)
    }

    @Test
    fun `一个带扩展名的候选都没有时取第一个非空值`() {
        val name = PickedFileNaming.resolve(listOf(null, "  ", "msf:1000000123"))

        assertEquals("msf:1000000123", name)
    }

    @Test
    fun `全部为空时回退到固定名字，不回传空串`() {
        assertEquals("selected", PickedFileNaming.resolve(listOf(null, "", "   ")))
        assertEquals("selected", PickedFileNaming.resolve(emptyList()))
    }

    @Test
    fun `不改写已有扩展名`() {
        // 回归防线：mp4 不能被当成 m4a 混进音频白名单。
        assertEquals("movie.mp4", PickedFileNaming.resolve(listOf("movie.mp4")))
    }

    @Test
    fun `剥掉路径分隔符，文件名不能写出目标目录`() {
        assertEquals("talk.mp3", PickedFileNaming.resolve(listOf("../../etc/talk.mp3")))
        assertEquals("talk.mp3", PickedFileNaming.resolve(listOf("..\\..\\talk.mp3")))
    }

    @Test
    fun `含空格与中文的名字原样保留`() {
        val name = PickedFileNaming.resolve(listOf("C2 - Conducting yourself 中文.m4a"))

        assertEquals("C2 - Conducting yourself 中文.m4a", name)
    }

    @Test
    fun `过长或非字母数字的后缀不算扩展名`() {
        // 带扩展名的候选优先，所以「什么算扩展名」判宽了会挑错候选。
        val name = PickedFileNaming.resolve(listOf("backup.2026-08-02", "talk.mp3"))

        assertEquals("talk.mp3", name)
    }
}
