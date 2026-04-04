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

import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

import org.apache.hadoop.hive.ql.metadata.Hive;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * [FIX] OHL-002 配套: 支持自动清理的线程池。
 *
 * 关键修复点: 在 afterExecute() 中:
 *   1. 调用 ThreadWithGarbageCleanup.cleanup() 释放 RawStore/PersistenceManager
 *   2. 调用 Hive.closeCurrent() 释放 MetaStore Thrift 连接 (修复 CL-001)
 *
 * 使用位置:
 *   替换 SessionManager 中三大线程池的创建方式:
 *   - backgroundOperationPool (HS2 异步查询池)
 *   - 或任何使用 ThreadFactoryWithGarbageCleanup 的线程池
 *
 * 示例:
 *   原代码: new ThreadPoolExecutor(..., new ThreadFactoryWithGarbageCleanup(...));
 *   修改为: new CleanupAwareThreadPoolExecutor(..., new ThreadFactoryWithGarbageCleanup(...));
 */
public class CleanupAwareThreadPoolExecutor extends ThreadPoolExecutor {

  private static final Logger LOG = LoggerFactory.getLogger(CleanupAwareThreadPoolExecutor.class);

  public CleanupAwareThreadPoolExecutor(
      int corePoolSize,
      int maximumPoolSize,
      long keepAliveTime,
      TimeUnit unit,
      BlockingQueue<Runnable> workQueue,
      ThreadFactory threadFactory) {
    super(corePoolSize, maximumPoolSize, keepAliveTime, unit, workQueue, threadFactory);
  }

  /**
   * 在每次任务执行完毕后自动清理线程资源。
   *
   * 这是修复的核心: 不再依赖 finalize()，而是在 afterExecute 回调中
   * 确定性地清理 RawStore 连接和 MetaStore Thrift 连接。
   */
  @Override
  protected void afterExecute(Runnable r, Throwable t) {
    try {
      super.afterExecute(r, t);

      Thread currentThread = Thread.currentThread();
      if (currentThread instanceof ThreadWithGarbageCleanup) {
        // [FIX OHL-002] 主动清理 RawStore，不依赖 finalize()
        ((ThreadWithGarbageCleanup) currentThread).cleanup();
      }

      // [FIX CL-001] 清理当前线程可能创建的 Hive 对象（内含 MetaStore Thrift 连接）
      try {
        Hive.closeCurrent();
      } catch (Exception e) {
        LOG.debug("Failed to close thread-local Hive object", e);
      }
    } catch (Exception e) {
      LOG.warn("Error in afterExecute cleanup", e);
    }
  }

  /**
   * 线程池关闭前清理所有线程资源。
   */
  @Override
  protected void terminated() {
    LOG.info("CleanupAwareThreadPoolExecutor terminated, all RawStore connections should be released.");
    super.terminated();
  }
}
