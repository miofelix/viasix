package dev.viasix.app.tun

import java.util.ArrayDeque
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** A bounded TUN writer queue where datagrams may yield, but TCP stream packets never do. */
class OutboundPacketQueue(capacity: Int) {
    private class Entry(
        val packet: ByteArray,
        val lossless: Boolean,
    )

    private val capacity = capacity.also { require(it > 0) }
    private val queue = ArrayDeque<Entry>(capacity)
    private val lock = ReentrantLock(true)
    private val notEmpty = lock.newCondition()
    private val notFull = lock.newCondition()
    private var cancelled = false

    fun offer(
        packet: ByteArray,
        lossless: Boolean,
        timeoutMs: Long = 0L,
    ): Boolean =
        lock.withLock {
            if (cancelled) return false
            val entry = Entry(packet, lossless)
            if (queue.size < capacity) {
                enqueue(entry)
                return true
            }
            if (removeDroppable()) {
                enqueue(entry)
                return true
            }
            if (!lossless) return false

            var remaining = TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtLeast(0L))
            while (!cancelled && queue.size >= capacity) {
                if (remaining <= 0L) return false
                remaining =
                    try {
                        notFull.awaitNanos(remaining)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return false
                    }
            }
            if (cancelled) return false
            enqueue(entry)
            true
        }

    fun poll(timeoutMs: Long): ByteArray? =
        lock.withLock {
            var remaining = TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtLeast(0L))
            while (!cancelled && queue.isEmpty()) {
                if (remaining <= 0L) return null
                remaining =
                    try {
                        notEmpty.awaitNanos(remaining)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        return null
                    }
            }
            if (cancelled) return null
            val entry = queue.removeFirst()
            notFull.signal()
            entry.packet
        }

    fun cancel() {
        lock.withLock {
            if (cancelled) return
            cancelled = true
            queue.clear()
            notEmpty.signalAll()
            notFull.signalAll()
        }
    }

    private fun removeDroppable(): Boolean {
        val iterator = queue.iterator()
        while (iterator.hasNext()) {
            if (!iterator.next().lossless) {
                iterator.remove()
                notFull.signal()
                return true
            }
        }
        return false
    }

    private fun enqueue(entry: Entry) {
        queue.addLast(entry)
        notEmpty.signal()
    }
}
