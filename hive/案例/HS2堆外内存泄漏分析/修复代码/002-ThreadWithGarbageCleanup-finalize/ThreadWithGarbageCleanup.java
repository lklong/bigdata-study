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

package org.apache.hive.service.server;

import java.util.Map;

import org.apache.hadoop.hive.metastore.HMSHandler;
import org.apache.hadoop.hive.metastore.RawStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * [FIX] OHL-002: 修复 finalize() 依赖不可靠导致 RawStore/PersistenceManager 泄漏。
 *
 * 根因: 线程退出时依赖 finalize() 关闭 PersistenceManager 连接，
 *       但 Java 9+ finalize() 已废弃且不保证执行时机，导致 JDBC 连接泄漏，
 *       pmCache 膨胀最终 OOM。
 *
 * 修复原理:
 *   1. 保留 finalize() 作为最后兜底(belt-and-suspenders)
 *   2. 新增 cleanup() 公开方法供 ThreadPoolExecutor.afterExecute() 主动调用
 *   3. 新增 ThreadFactoryWithCleanup 配套的 CleanupAwareThreadPoolExecutor
 *
 * 影响版本: Hive 2.3.x, Hive 3.0-3.1.x (HIVE-20192 部分修复了 3.2+)
 */
public class ThreadWithGarbageCleanup extends Thread {
  private static final Logger LOG = LoggerFactory.getLogger(ThreadWithGarbageCleanup.class);

  Map<Long, RawStore> threadRawStoreMap =
      ThreadFactoryWithGarbageCleanup.getThreadRawStoreMap();

  public ThreadWithGarbageCleanup(Runnable runnable) {
    super(runnable);
  }

  // ====== BEGIN FIX ======

  /**
   * 主动清理方法 — 由 CleanupAwareThreadPoolExecutor.afterExecute() 调用。
   * 不再依赖不可靠的 finalize()。
   *
   * 每次任务执行完毕后立即调用，确保 RawStore 连接及时释放。
   */
  public void cleanup() {
    cleanRawStore();
  }

  // ====== END FIX ======

  /**
   * [DEPRECATED] 保留 finalize() 作为最后兜底，但不再是主要清理路径。
   * Java 9+ 此方法不保证执行时机和执行顺序。
   */
  @Override
  @SuppressWarnings("deprecation")
  public void finalize() throws Throwable {
    cleanRawStore();
    super.finalize();
  }

  private void cleanRawStore() {
    Long threadId = this.getId();
    RawStore threadLocalRawStore = threadRawStoreMap.get(threadId);
    if (threadLocalRawStore != null) {
      LOG.debug("RawStore: " + threadLocalRawStore + ", for the thread: " +
          this.getName()  +  " will be closed now.");
      try {
        threadLocalRawStore.shutdown();
      } catch (Exception e) {
        LOG.warn("Failed to shutdown RawStore for thread: " + this.getName(), e);
      }
      threadRawStoreMap.remove(threadId);
    }
  }

  /**
   * Cache the ThreadLocal RawStore object. Called from the corresponding thread.
   */
  public void cacheThreadLocalRawStore() {
    Long threadId = this.getId();
    RawStore threadLocalRawStore = HMSHandler.getRawStore();
    if (threadLocalRawStore == null) {
      LOG.debug("Thread Local RawStore is null, for the thread: " +
              this.getName() + " and so removing entry from threadRawStoreMap.");
      threadRawStoreMap.remove(threadId);
    } else {
      LOG.debug("Adding RawStore: " + threadLocalRawStore + ", for the thread: " +
          this.getName() + " to threadRawStoreMap for future cleanup.");
      threadRawStoreMap.put(threadId, threadLocalRawStore);
    }
  }
}
