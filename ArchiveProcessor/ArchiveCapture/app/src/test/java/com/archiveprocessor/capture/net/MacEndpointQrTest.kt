package com.archiveprocessor.capture.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A5 backward-compatibility guard for the combined pairing QR. The Mac now emits ONE QR
 * `{host,port,token,name}` PLUS an OPTIONAL `relay` key. This proves the Android parser:
 *  - still pairs an OLD LAN-only QR (no `relay`) byte-for-byte (LAN path unbroken),
 *  - reads `relay` from the combined QR and exposes it for the Cloud path,
 *  - tolerates a legacy `{mode:"cloud",…}` QR, and derives `relayToken` correctly in every case.
 * Plain-JVM (org.json only), no emulator.
 */
class MacEndpointQrTest {

    @Test fun legacyLanQr_parsesWithNoRelay() {
        val ep = MacEndpoint.fromQrPayload("""{"host":"192.168.1.5","port":48627,"token":"ABC234","name":"Mac"}""")
        assertNotNull(ep); ep!!
        assertEquals("192.168.1.5", ep.host)
        assertEquals(48627, ep.port)
        assertEquals("ABC234", ep.token)
        assertTrue(!ep.isCloud)
        assertNull("legacy LAN QR must tolerate an absent relay key", ep.relay)
        assertNull("no relay + LAN ⇒ Cloud unavailable from that scan", ep.relayToken)
    }

    @Test fun combinedQr_yieldsLanEndpointAndReadsRelay() {
        val ep = MacEndpoint.fromQrPayload(
            """{"host":"192.168.1.5","port":48627,"token":"ABC234","name":"Mac","relay":"ABC234"}""")
        assertNotNull(ep); ep!!
        assertEquals("192.168.1.5", ep.host)   // LAN pairing still works from the same QR
        assertEquals(48627, ep.port)
        assertEquals("ABC234", ep.token)
        assertTrue(!ep.isCloud)
        assertEquals("ABC234", ep.relay)        // Cloud path can read it
        assertEquals("ABC234", ep.relayToken)
    }

    @Test fun combinedQr_stringPortAndUnknownKeysTolerated() {
        val ep = MacEndpoint.fromQrPayload(
            """{"host":"10.0.0.2","port":"48627","token":"XYZ789","name":"Mac","relay":"XYZ789","future":"x"}""")
        assertNotNull(ep); ep!!
        assertEquals(48627, ep.port)
        assertEquals("XYZ789", ep.relayToken)
    }

    @Test fun legacyCloudQr_stillAccepted() {
        val ep = MacEndpoint.fromQrPayload("""{"mode":"cloud","token":"REL123","name":"Mac"}""")
        assertNotNull(ep); ep!!
        assertTrue(ep.isCloud)
        assertEquals("REL123", ep.relayToken)   // relay omitted ⇒ falls back to token for a cloud endpoint
    }

    @Test fun malformedQr_returnsNull() {
        assertNull(MacEndpoint.fromQrPayload("not json"))
        assertNull(MacEndpoint.fromQrPayload("""{"host":"h","port":0,"token":"t"}"""))   // bad port
        assertNull(MacEndpoint.fromQrPayload("""{"host":"h","port":5}"""))               // no token
    }
}
