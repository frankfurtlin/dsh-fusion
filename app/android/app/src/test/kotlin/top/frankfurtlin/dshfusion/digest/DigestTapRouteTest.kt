package top.frankfurtlin.dshfusion.digest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.net.URI

/**
 * 兴趣推送的点击去处必须是一条 App 页面链接，Dart 侧
 * `pageLinkId`（app/lib/links/page_links.dart）只认 `dshgo://open/<id>`：
 * 不带用户信息、端口、查询和片段，路径正好一段。
 *
 * `<id>` 能不能打开那一页由 Dart 侧的
 * `test/digest/digest_tap_route_test.dart` 守着（两边是同一个约定）。
 */
class DigestTapRouteTest {
    @Test
    fun theTapIsAPageLink() {
        val uri = URI(DigestSync.TAP_URI)
        assertEquals("dshgo", uri.scheme)
        assertEquals("open", uri.host)
        assertEquals("/" + DigestSync.PAGE_ID, uri.path)
        assertNull(uri.query)
        assertNull(uri.fragment)
        assertNull(uri.userInfo)
        assertEquals(-1, uri.port)
    }

    @Test
    fun theTapNamesTheDiscoverPage() {
        assertEquals("digest", DigestSync.PAGE_ID)
        assertEquals("dshgo://open/digest", DigestSync.TAP_URI)
    }
}
