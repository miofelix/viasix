package dev.viasix.app.tun

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class OutboundPacketQueueTest {
    @Test
    fun droppablePacketNeverEvictsLosslessTcpPacket() {
        val queue = OutboundPacketQueue(capacity = 1)
        val tcp = byteArrayOf(1)

        assertTrue(queue.offer(tcp, lossless = true))
        assertFalse(queue.offer(byteArrayOf(2), lossless = false))
        assertArrayEquals(tcp, queue.poll(timeoutMs = 0L))
    }

    @Test
    fun newestDatagramMayReplaceOlderDroppablePacket() {
        val queue = OutboundPacketQueue(capacity = 1)

        assertTrue(queue.offer(byteArrayOf(1), lossless = false))
        assertTrue(queue.offer(byteArrayOf(2), lossless = false))
        assertArrayEquals(byteArrayOf(2), queue.poll(timeoutMs = 0L))
        assertNull(queue.poll(timeoutMs = 0L))
    }

    @Test
    fun losslessPacketEvictsQueuedDatagramBeforeWaiting() {
        val queue = OutboundPacketQueue(capacity = 1)
        val tcp = byteArrayOf(2)

        assertTrue(queue.offer(byteArrayOf(1), lossless = false))
        assertTrue(queue.offer(tcp, lossless = true, timeoutMs = 0L))

        assertArrayEquals(tcp, queue.poll(timeoutMs = 0L))
        assertNull(queue.poll(timeoutMs = 0L))
    }

    @Test
    fun losslessPacketDoesNotEvictAnotherLosslessPacket() {
        val queue = OutboundPacketQueue(capacity = 1)
        val first = byteArrayOf(1)

        assertTrue(queue.offer(first, lossless = true))
        assertFalse(queue.offer(byteArrayOf(2), lossless = true, timeoutMs = 0L))

        assertArrayEquals(first, queue.poll(timeoutMs = 0L))
    }

    @Test
    fun cancelledQueueCannotBeRevivedByWaitingProducer() {
        val queue = OutboundPacketQueue(capacity = 1)
        val started = CountDownLatch(1)
        val result = AtomicReference<Boolean?>(null)
        assertTrue(queue.offer(byteArrayOf(1), lossless = true))
        val producer =
            Thread {
                started.countDown()
                result.set(queue.offer(byteArrayOf(2), lossless = true, timeoutMs = 2_000L))
            }.apply {
                isDaemon = true
                start()
            }

        assertTrue(started.await(1, TimeUnit.SECONDS))
        assertTrue(awaitState(producer, Thread.State.TIMED_WAITING))
        queue.cancel()
        producer.join(1_000L)

        assertFalse(producer.isAlive)
        assertFalse(result.get() ?: true)
        assertNull(queue.poll(timeoutMs = 0L))
        assertFalse(queue.offer(byteArrayOf(3), lossless = true, timeoutMs = 0L))
        assertFalse(queue.offer(byteArrayOf(4), lossless = false))
    }

    @Test
    fun blockedLosslessProducerDoesNotBlockOtherProducers() {
        val queue = OutboundPacketQueue(capacity = 1)
        assertTrue(queue.offer(byteArrayOf(1), lossless = true))
        val executor = Executors.newFixedThreadPool(2)

        try {
            val waitingLossless =
                executor.submit<Boolean> {
                    queue.offer(byteArrayOf(2), lossless = true, timeoutMs = 5_000L)
                }
            Thread.sleep(50L)
            val datagram =
                executor.submit<Boolean> {
                    queue.offer(byteArrayOf(3), lossless = false)
                }

            assertFalse(datagram.get(1, TimeUnit.SECONDS))
            queue.cancel()
            assertFalse(waitingLossless.get(1, TimeUnit.SECONDS))
        } finally {
            queue.cancel()
            executor.shutdownNow()
        }
    }

    private fun awaitState(
        thread: Thread,
        expected: Thread.State,
    ): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1L)
        while (System.nanoTime() < deadline) {
            if (thread.state == expected) return true
            if (!thread.isAlive) return false
            Thread.yield()
        }
        return thread.state == expected
    }
}
