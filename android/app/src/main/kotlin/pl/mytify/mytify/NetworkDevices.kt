package pl.mytify.mytify

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import java.io.*
import java.net.*
import java.util.concurrent.*
import javax.xml.parsers.DocumentBuilderFactory
import org.json.JSONArray
import org.w3c.dom.Element

data class NetworkTarget(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val kind: String,
    val control: String = "",
    val rendering: String = "",
    val service: String = "",
    val auth: Int = 0,
    val ap2: Boolean = false,
)

object NetworkDevices {
    val targets = ConcurrentHashMap<String, NetworkTarget>()

    /** One id per AirPlay receiver: "deviceid" of _airplay or the MAC before '@' of _raop. */
    fun airplayDeviceId(instance: String, deviceId: String): String? {
        val raw = deviceId.ifBlank { instance.substringBefore('@', "") }
        val hex = raw.filter { it.isDigit() || it.lowercaseChar() in 'a'..'f' }.uppercase()
        if (hex.length != 12) return deviceId.ifBlank { null }?.uppercase()
        return hex.chunked(2).joinToString(":")
    }

    fun privateHost(host: String): Boolean {
        val p = host.split('.').mapNotNull { it.toIntOrNull() }
        return p.size == 4 &&
            p.all { it in 0..255 } &&
            (p[0] == 10 ||
                p[0] == 192 && p[1] == 168 ||
                p[0] == 172 && p[1] in 16..31 ||
                p[0] == 169 && p[1] == 254)
    }

    fun localUrl(value: String, host: String? = null): URL {
        val u = URL(value)
        require(
            u.protocol == "http" &&
                privateHost(u.host) &&
                (host == null || host == u.host) &&
                u.userInfo == null
        ) {
            "Nieprawidłowy adres odbiornika"
        }
        return u
    }

    fun http(url: URL, body: String? = null, soap: String? = null): String {
        localUrl(url.toString())
        val c = url.openConnection() as HttpURLConnection
        c.connectTimeout = 3000
        c.readTimeout = 3000
        c.instanceFollowRedirects = false
        try {
            if (body != null) {
                c.requestMethod = "POST"
                c.doOutput = true
                c.setRequestProperty("Content-Type", "text/xml; charset=utf-8")
                if (soap != null) c.setRequestProperty("SOAPACTION", soap)
                c.outputStream.use { it.write(body.toByteArray()) }
            }
            check(c.responseCode in 200..299) {
                "Odbiornik zwrócił ${c.responseCode}. Sprawdź DMC Control i obsługiwany format."
            }
            return c.inputStream.use { String(readLimited(it, 1024 * 1024)) }
        } finally {
            c.disconnect()
        }
    }

    fun document(text: String): org.w3c.dom.Document {
        require(!Regex("<!\\s*(DOCTYPE|ENTITY)", RegexOption.IGNORE_CASE).containsMatchIn(text)) {
            "Deklaracje DTD nie są obsługiwane"
        }
        return DocumentBuilderFactory.newInstance()
            .apply {
                isNamespaceAware = true
                isExpandEntityReferences = false
            }
            .newDocumentBuilder()
            .parse(ByteArrayInputStream(text.toByteArray()))
    }

    fun mime(format: String): String =
        when (format.lowercase()) {
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            "m4a",
            "mp4" -> "audio/mp4"
            "aac" -> "audio/aac"
            "aif",
            "aiff" -> "audio/aiff"
            "ogg",
            "opus" -> "audio/ogg"
            "mp3" -> "audio/mpeg"
            else -> "application/octet-stream"
        }

    fun xml(text: String, key: String): String =
        runCatching { document(text).getElementsByTagNameNS("*", key).item(0)?.textContent ?: "" }
            .getOrDefault("")

    fun escape(s: String) =
        s.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&apos;")

    fun describe(location: String): NetworkTarget {
        val base = localUrl(location)
        val text = http(base)
        val d = document(text)
        val serviceBase = localUrl(xml(text, "URLBase").ifBlank { base.toString() }, base.host)
        var control = ""
        var rendering = ""
        var service = ""
        val list = d.getElementsByTagNameNS("*", "service")
        for (i in 0 until list.length) {
            val e = list.item(i) as Element
            fun get(k: String) = e.getElementsByTagNameNS("*", k).item(0)?.textContent ?: ""
            val type = get("serviceType")
            val endpoint =
                localUrl(URL(serviceBase, get("controlURL")).toString(), base.host).toString()
            if (type.startsWith("urn:schemas-upnp-org:service:AVTransport:")) {
                control = endpoint
                service = type
            }
            if (type.startsWith("urn:schemas-upnp-org:service:RenderingControl:"))
                rendering = endpoint
        }
        check(control.isNotEmpty()) { "Urządzenie nie udostępnia DLNA AVTransport" }
        val yamaha = xml(text, "manufacturer").contains("yamaha", true)
        return NetworkTarget(
            "dlna:" + xml(text, "UDN").ifBlank { base.toString() },
            xml(text, "friendlyName").ifBlank { "Odbiornik" } +
                if (yamaha) " · Yamaha / MusicCast (DLNA)" else " · DLNA",
            base.host,
            if (base.port < 0) 80 else base.port,
            "dlna",
            control,
            rendering,
            service,
        )
    }

    fun soap(
        t: NetworkTarget,
        action: String,
        args: Map<String, String> = emptyMap(),
        render: Boolean = false,
    ): String {
        val service = if (render) "urn:schemas-upnp-org:service:RenderingControl:1" else t.service
        val url = localUrl(if (render) t.rendering else t.control, t.host)
        val body =
            "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$action xmlns:u=\"$service\"><InstanceID>0</InstanceID>" +
                args.entries.joinToString("") { "<${it.key}>${escape(it.value)}</${it.key}>" } +
                "</u:$action></s:Body></s:Envelope>"
        return http(url, body, "\"$service#$action\"")
    }

    @Suppress("DEPRECATION")
    fun discover(context: Context): JSONArray {
        val found = ConcurrentHashMap<String, NetworkTarget>()
        val executor = Executors.newFixedThreadPool(4)
        val lock =
            (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createMulticastLock("mytify-discovery")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val queue = ConcurrentLinkedQueue<NsdServiceInfo>()
        val listeners = mutableListOf<NsdManager.DiscoveryListener>()
        try {
            for (type in listOf("_raop._tcp.", "_airplay._tcp.")) {
                val listener =
                    object : NsdManager.DiscoveryListener {
                        override fun onDiscoveryStarted(s: String) {}

                        override fun onDiscoveryStopped(s: String) {}

                        override fun onStartDiscoveryFailed(s: String, e: Int) {}

                        override fun onStopDiscoveryFailed(s: String, e: Int) {}

                        override fun onServiceFound(s: NsdServiceInfo) {
                            if (queue.size < 32) queue.add(s)
                        }

                        override fun onServiceLost(s: NsdServiceInfo) {}
                    }
                listeners.add(listener)
                runCatching { nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener) }
            }
            val udp =
                executor.submit {
                    DatagramSocket().use { s ->
                        s.soTimeout = 200
                        val msg =
                            "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
                                .toByteArray()
                        s.send(
                            DatagramPacket(
                                msg,
                                msg.size,
                                InetAddress.getByName("239.255.255.250"),
                                1900,
                            )
                        )
                        val end = System.nanoTime() + 2200000000
                        val seen = mutableSetOf<String>()
                        while (System.nanoTime() < end) {
                            try {
                                val p = DatagramPacket(ByteArray(8192), 8192)
                                s.receive(p)
                                if (!privateHost(p.address.hostAddress ?: "")) continue
                                val loc =
                                    String(p.data, 0, p.length)
                                        .lineSequence()
                                        .mapNotNull {
                                            val a = it.split(':', limit = 2)
                                            if (a.size == 2 && a[0].equals("location", true))
                                                a[1].trim()
                                            else null
                                        }
                                        .firstOrNull()
                                if (loc != null && seen.size < 24 && seen.add(loc))
                                    executor.execute {
                                        runCatching { describe(loc) }
                                            .getOrNull()
                                            ?.let { found[it.id] = it }
                                    }
                            } catch (_: SocketTimeoutException) {}
                        }
                    }
                }
            val end = System.nanoTime() + 3500000000
            while (System.nanoTime() < end) {
                val info = queue.poll()
                if (info == null) {
                    Thread.sleep(40)
                    continue
                }
                val latch = CountDownLatch(1)
                runCatching {
                    nsd.resolveService(
                        info,
                        object : NsdManager.ResolveListener {
                            override fun onResolveFailed(s: NsdServiceInfo, e: Int) {
                                latch.countDown()
                            }

                            override fun onServiceResolved(s: NsdServiceInfo) {
                                try {
                                    val host = s.host?.hostAddress ?: return
                                    if (!privateHost(host)) return
                                    fun attr(k: String) =
                                        s.attributes[k]?.toString(Charsets.UTF_8) ?: ""
                                    val model = attr("am")
                                    val ap2 =
                                        s.serviceType.startsWith("_airplay") ||
                                            attr("pk").length > 8
                                    val auth =
                                        if (attr("pw") == "true") 1
                                        else if (ap2) {
                                            if (model.startsWith("AppleTV")) 5 else 4
                                        } else if (model.startsWith("AirPort")) 2 else 0
                                    val id =
                                        "airplay:" +
                                            (airplayDeviceId(s.serviceName, attr("deviceid"))
                                                ?: (s.serviceName + host))
                                    val raop = s.serviceType.contains("_raop")
                                    // One receiver comes as _raop and _airplay; streaming uses RAOP.
                                    if (!raop && found[id]?.service == "raop") return
                                    found[id] =
                                        NetworkTarget(
                                            id,
                                            s.serviceName.substringAfter('@') +
                                                " · AirPlay" +
                                                if (ap2) " 2" else "",
                                            host,
                                            s.port,
                                            "airplay",
                                            service = if (raop) "raop" else "airplay",
                                            auth = auth,
                                            ap2 = ap2,
                                        )
                                } finally {
                                    latch.countDown()
                                }
                            }
                        },
                    )
                }
                latch.await(500, TimeUnit.MILLISECONDS)
            }
            runCatching { udp.get(300, TimeUnit.MILLISECONDS) }
        } finally {
            listeners.forEach { runCatching { nsd.stopServiceDiscovery(it) } }
            executor.shutdown()
            executor.awaitTermination(4, TimeUnit.SECONDS)
            lock.release()
        }
        targets.clear()
        targets.putAll(found)
        return JSONArray(
            listOf(obj("id" to "auto", "name" to "Ten telefon / wyjście systemowe")) +
                found.values.sortedBy { it.name }.map { obj("id" to it.id, "name" to it.name) }
        )
    }
}

class NetworkFileServer(
    private val context: Context,
    private val catalog: Catalog,
    private val target: NetworkTarget,
) : AutoCloseable {
    private val server = ServerSocket(0)
    private val workers = Executors.newFixedThreadPool(3)
    @Volatile private var closed = false
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    private val token = java.util.UUID.randomUUID().toString()
    @Volatile private var allowed = ""
    private val thread =
        Thread {
                while (!closed) {
                    try {
                        val s = server.accept()
                        if (sockets.size >= 3 || s.inetAddress.hostAddress != target.host) s.close()
                        else {
                            sockets.add(s)
                            workers.execute {
                                try {
                                    serve(s)
                                } catch (_: Exception) {} finally {
                                    sockets.remove(s)
                                    runCatching { s.close() }
                                }
                            }
                        }
                    } catch (_: Exception) {}
                }
            }
            .apply {
                isDaemon = true
                start()
            }

    fun uri(id: String): String {
        catalog.uri(id)
        allowed = id
        val local =
            DatagramSocket().use {
                it.connect(InetAddress.getByName(target.host), target.port)
                it.localAddress.hostAddress
            }
        return "http://$local:${server.localPort}/$token/$id"
    }

    private fun serve(s: Socket) {
        s.soTimeout = 5000
        val input = s.getInputStream().buffered()
        fun line(): String {
            val b = ByteArrayOutputStream()
            while (b.size() < 4096) {
                val c = input.read()
                if (c < 0 || c == 10) break
                b.write(c)
            }
            return b.toString("US-ASCII").trimEnd('\r')
        }
        val request = line().split(' ')
        if (request.size < 2) return
        val headers = mutableMapOf<String, String>()
        for (i in 0 until 32) {
            val l = line()
            if (l.isEmpty()) break
            val p = l.split(':', limit = 2)
            if (p.size == 2) headers[p[0].lowercase()] = p[1].trim()
        }
        val output = s.getOutputStream()
        fun reply(code: Int, extra: String = "", body: ((OutputStream) -> Unit)? = null) {
            output.write(
                "HTTP/1.1 $code ${if(code==200)"OK"else if(code==206)"Partial Content"else "Error"}\r\nConnection: close\r\n$extra\r\n"
                    .toByteArray()
            )
            if (body != null && request[0] != "HEAD") body(output)
            output.flush()
        }
        val id = request[1].removePrefix("/$token/")
        if (
            request[1] != "/$token/$allowed" ||
                allowed.isEmpty() ||
                request[0] !in listOf("GET", "HEAD")
        ) {
            reply(403)
            return
        }
        val track = catalog.track(id)
        val len = track.optLong("size")
        if (len <= 0) {
            reply(404)
            return
        }
        var start = 0L
        var end = len - 1
        val range = headers["range"]
        if (range != null) {
            val r = parseRange(range, len)
            if (r == null) {
                reply(416, "Content-Range: bytes */$len\r\n")
                return
            }
            start = r.first
            end = r.second
        }
        val uri = catalog.uri(id)
        if (uri.scheme == "smb") {
            // NAS track cast to a renderer: stream the requested range straight from the share.
            NetworkSources.stream(context, uri, start).use { input ->
                val mime = NetworkDevices.mime(track.optString("format"))
                reply(
                    if (range == null) 200 else 206,
                    "Content-Type: $mime\r\nContent-Length: ${end-start+1}\r\nAccept-Ranges: bytes\r\ntransferMode.dlna.org: Streaming\r\n" +
                        if (range != null) "Content-Range: bytes $start-$end/$len\r\n" else "",
                ) { out ->
                    var left = end - start + 1
                    val buffer = ByteArray(65536)
                    while (left > 0 && !closed) {
                        val n = input.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        left -= n
                    }
                }
            }
            return
        }
        context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { fd ->
            FileInputStream(fd.fileDescriptor).use { file ->
                file.channel.position(fd.startOffset + start)
                val mime = NetworkDevices.mime(track.optString("format"))
                reply(
                    if (range == null) 200 else 206,
                    "Content-Type: $mime\r\nContent-Length: ${end-start+1}\r\nAccept-Ranges: bytes\r\ntransferMode.dlna.org: Streaming\r\n" +
                        if (range != null) "Content-Range: bytes $start-$end/$len\r\n" else "",
                ) { out ->
                    var left = end - start + 1
                    val buffer = ByteArray(65536)
                    while (left > 0 && !closed) {
                        val n = file.read(buffer, 0, minOf(buffer.size.toLong(), left).toInt())
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        left -= n
                    }
                }
            }
        } ?: reply(404)
    }

    override fun close() {
        closed = true
        allowed = ""
        runCatching { server.close() }
        sockets.forEach { runCatching { it.close() } }
        workers.shutdownNow()
    }

    companion object {
        fun parseRange(s: String, len: Long): Pair<Long, Long>? =
            runCatching {
                    require(len > 0 && s.startsWith("bytes=") && !s.contains(','))
                    val p = s.substring(6).split('-', limit = 2)
                    require(p.size == 2)
                    val a: Long
                    val b: Long
                    if (p[0].isEmpty()) {
                        val n = p[1].toLong()
                        require(n > 0)
                        a = maxOf(0, len - n)
                        b = len - 1
                    } else {
                        a = p[0].toLong()
                        b = if (p[1].isEmpty()) len - 1 else minOf(len - 1, p[1].toLong())
                    }
                    require(a in 0 until len && b >= a)
                    a to b
                }
                .getOrNull()
    }
}
