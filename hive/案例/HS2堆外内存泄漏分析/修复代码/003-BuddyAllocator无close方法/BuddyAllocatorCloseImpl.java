/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package org.apache.hadoop.hive.llap.cache;

import java.io.Closeable;
import java.io.IOException;
import java.nio.ByteBuffer;

import org.apache.hive.common.util.CleanerUtil;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * [FIX] OHL-003: BuddyAllocator close() 实现 — 可直接复制到 BuddyAllocator 类中。
 *
 * 根因: BuddyAllocator 没有 close/destroy 方法，每个 Arena 持有最大 1GB 的
 *       DirectByteBuffer，完全依赖 GC Cleaner 释放。高负载下 Cleaner 线程
 *       严重滞后，LLAP Daemon 关闭后 GB 级离堆内存不归还。
 *
 * 修复原理:
 *   1. 让 BuddyAllocator 实现 Closeable 接口
 *   2. close() 方法遍历所有已分配 Arena，对 Direct/Mapped ByteBuffer 调用 CleanerUtil 释放
 *   3. LlapIoImpl.close() 中调用 buddyAllocator.close()
 *
 * 影响版本: Hive 2.3.x (LLAP), Hive 3.x (LLAP), 所有版本 trunk 均未修复
 */
public class BuddyAllocatorCloseImpl {

  private static final Logger LOG = LoggerFactory.getLogger(BuddyAllocatorCloseImpl.class);

  // ==================== 以下代码需要添加到 BuddyAllocator.java 中 ====================

  /**
   * 将此方法添加到 BuddyAllocator 类中。
   * 类声明需改为: implements EvictionAwareAllocator, StoppableAllocator, BuddyAllocatorMXBean, LlapIoDebugDump, Closeable
   *
   * @throws IOException 如果释放过程中出错
   */
  public static void closeImpl(Object[] arenas, boolean isDirect, Logger log) throws IOException {
    if (arenas == null) {
      return;
    }

    log.info("BuddyAllocator.close(): releasing {} arenas", arenas.length);
    int releasedCount = 0;
    int failedCount = 0;

    for (int i = 0; i < arenas.length; i++) {
      // Arena 是 BuddyAllocator 的内部类，通过反射或直接访问 data 字段
      // 在实际补丁中，直接访问 arenas[i].data
      ByteBuffer arenaData = getArenaData(arenas[i]);
      if (arenaData == null) {
        continue; // 未分配的 Arena
      }

      if (arenaData.isDirect()) {
        try {
          if (CleanerUtil.UNMAP_SUPPORTED) {
            CleanerUtil.getCleaner().freeBuffer(arenaData);
            releasedCount++;
            log.debug("Arena[{}]: released {} bytes DirectByteBuffer via CleanerUtil",
                i, arenaData.capacity());
          } else {
            // Fallback: 尝试通过反射调用 Cleaner
            boolean freed = fallbackFreeDirectBuffer(arenaData);
            if (freed) {
              releasedCount++;
              log.debug("Arena[{}]: released {} bytes via fallback cleaner", i, arenaData.capacity());
            } else {
              failedCount++;
              log.warn("Arena[{}]: cannot release {} bytes DirectByteBuffer - CleanerUtil not supported and fallback failed. "
                  + "Reason: {}", i, arenaData.capacity(), CleanerUtil.UNMAP_NOT_SUPPORTED_REASON);
            }
          }
        } catch (Exception e) {
          failedCount++;
          log.warn("Arena[{}]: failed to release DirectByteBuffer", i, e);
        }
      }
      // Heap ByteBuffer 不需要显式释放，GC 自动回收
    }

    log.info("BuddyAllocator.close() complete: released={}, failed={}, total={}",
        releasedCount, failedCount, arenas.length);
  }

  /**
   * Fallback: 当 CleanerUtil.UNMAP_SUPPORTED=false 时的 DirectByteBuffer 释放。
   * 通过反射直接调用 sun.misc.Cleaner.clean() 或 jdk.internal.ref.Cleaner.clean()。
   */
  private static boolean fallbackFreeDirectBuffer(ByteBuffer buffer) {
    if (!buffer.isDirect()) {
      return false;
    }
    try {
      // Java 8: sun.misc.Cleaner
      java.lang.reflect.Method cleanerMethod = buffer.getClass().getMethod("cleaner");
      cleanerMethod.setAccessible(true);
      Object cleaner = cleanerMethod.invoke(buffer);
      if (cleaner != null) {
        java.lang.reflect.Method cleanMethod = cleaner.getClass().getMethod("clean");
        cleanMethod.setAccessible(true);
        cleanMethod.invoke(cleaner);
        return true;
      }
    } catch (NoSuchMethodException e) {
      // Java 9+: try Unsafe.invokeCleaner
      try {
        Class<?> unsafeClass = Class.forName("sun.misc.Unsafe");
        java.lang.reflect.Field f = unsafeClass.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        Object unsafe = f.get(null);
        java.lang.reflect.Method invokeCleanerMethod =
            unsafeClass.getMethod("invokeCleaner", ByteBuffer.class);
        invokeCleanerMethod.invoke(unsafe, buffer);
        return true;
      } catch (Exception ex) {
        LOG.debug("Fallback cleaner via Unsafe also failed", ex);
      }
    } catch (Exception e) {
      LOG.debug("Fallback cleaner failed", e);
    }
    return false;
  }

  /**
   * 实际补丁中应直接访问 Arena.data 字段。
   * 此处为示意，实际使用时删除此方法。
   */
  private static ByteBuffer getArenaData(Object arena) {
    try {
      java.lang.reflect.Field dataField = arena.getClass().getDeclaredField("data");
      dataField.setAccessible(true);
      return (ByteBuffer) dataField.get(arena);
    } catch (Exception e) {
      return null;
    }
  }

  // ==================== 实际补丁代码（直接添加到 BuddyAllocator.java） ====================

  /**
   * 以下是完整的 close() 方法，直接复制到 BuddyAllocator 类中:
   *
   * <pre>
   * {@code
   * @Override
   * public void close() throws IOException {
   *     LOG.info("BuddyAllocator.close(): releasing {} arenas, isDirect={}", arenas.length, isDirect);
   *     int releasedCount = 0;
   *     int failedCount = 0;
   *
   *     for (int i = 0; i < arenas.length; i++) {
   *         ByteBuffer arenaData = arenas[i].data;
   *         if (arenaData == null) {
   *             continue;
   *         }
   *
   *         if (arenaData.isDirect()) {
   *             try {
   *                 if (CleanerUtil.UNMAP_SUPPORTED) {
   *                     CleanerUtil.getCleaner().freeBuffer(arenaData);
   *                     releasedCount++;
   *                 } else {
   *                     // Fallback for environments where CleanerUtil is not supported
   *                     LOG.warn("Arena[{}]: CleanerUtil not supported ({}), "
   *                         + "DirectByteBuffer of {} bytes will rely on GC",
   *                         i, CleanerUtil.UNMAP_NOT_SUPPORTED_REASON, arenaData.capacity());
   *                     failedCount++;
   *                 }
   *             } catch (Exception e) {
   *                 failedCount++;
   *                 LOG.warn("Arena[{}]: failed to release DirectByteBuffer of {} bytes",
   *                     i, arenaData.capacity(), e);
   *             }
   *         }
   *         // null out reference to help GC
   *         arenas[i].data = null;
   *     }
   *
   *     // Clean up thread-local discard context
   *     threadCtx.remove();
   *
   *     LOG.info("BuddyAllocator.close() complete: released={}, failed={}, totalArenas={}",
   *         releasedCount, failedCount, arenas.length);
   * }
   * }
   * </pre>
   */
  public void closeExample() {
    // 见上方注释中的实际代码
  }
}
