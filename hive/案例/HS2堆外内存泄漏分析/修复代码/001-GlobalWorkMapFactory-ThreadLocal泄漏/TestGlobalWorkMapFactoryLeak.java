/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.hadoop.hive.ql.exec;

import static org.junit.Assert.*;

import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.hive.conf.HiveConf;
import org.apache.hadoop.hive.ql.plan.BaseWork;
import org.apache.hadoop.hive.ql.plan.MapWork;
import org.apache.hadoop.hive.ql.session.SessionState;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

/**
 * 复现和验证 OHL-001: GlobalWorkMapFactory ThreadLocal 泄漏。
 *
 * 复现方法:
 *   模拟 HS2 线程池复用线程执行多次查询场景，
 *   验证不调用 clear 时 Map 持续增长，调用 clear 后 Map 被正确清理。
 *
 * 运行方式:
 *   mvn test -pl ql -Dtest=TestGlobalWorkMapFactoryLeak -DskipTests=false
 */
public class TestGlobalWorkMapFactoryLeak {

  private GlobalWorkMapFactory factory;
  private HiveConf conf;

  @Before
  public void setUp() {
    factory = new GlobalWorkMapFactory();
    conf = new HiveConf();
    // 模拟 HiveServer2 查询模式
    SessionState ss = new SessionState(conf);
    SessionState.setCurrentSessionState(ss);
    ss.setIsHiveServerQuery(true);
  }

  @After
  public void tearDown() {
    SessionState.detachSession();
  }

  /**
   * 复现 Bug: 验证未调用 clear 时 ThreadLocal Map 只增不减。
   */
  @Test
  public void testLeakWithoutClear() {
    // 模拟 10 次查询，每次 put 10 个 BaseWork
    for (int query = 0; query < 10; query++) {
      Map<Path, BaseWork> workMap = factory.get(conf);
      for (int i = 0; i < 10; i++) {
        Path path = new Path("/tmp/query_" + query + "/stage_" + i);
        workMap.put(path, new MapWork()); // MapWork extends BaseWork
      }
      // 模拟查询结束但没有 clear — 这就是 bug！
    }

    // 验证: 10 次查询后，Map 中应有 100 个条目（泄漏！）
    Map<Path, BaseWork> workMap = factory.get(conf);
    assertEquals("BUG REPRODUCED: ThreadLocal Map accumulated entries across queries",
        100, workMap.size());
  }

  /**
   * 验证修复: 调用 clearThreadLocalWorkMap() 后 Map 被正确清理。
   */
  @Test
  public void testFixWithClear() {
    for (int query = 0; query < 10; query++) {
      Map<Path, BaseWork> workMap = factory.get(conf);
      for (int i = 0; i < 10; i++) {
        Path path = new Path("/tmp/query_" + query + "/stage_" + i);
        workMap.put(path, new MapWork());
      }
      // [FIX] 每次查询结束后清理
      factory.clearThreadLocalWorkMap();
    }

    // 验证: 清理后 Map 应为空
    Map<Path, BaseWork> workMap = factory.get(conf);
    assertEquals("FIX VERIFIED: ThreadLocal Map should be empty after clear", 0, workMap.size());
  }

  /**
   * 验证修复: removeThreadLocalWorkMap() 彻底移除 ThreadLocal 条目。
   */
  @Test
  public void testFixWithRemove() {
    Map<Path, BaseWork> workMap = factory.get(conf);
    workMap.put(new Path("/tmp/test"), new MapWork());
    assertEquals(1, workMap.size());

    // 彻底移除
    factory.removeThreadLocalWorkMap();

    // 再次 get 应得到全新的空 Map
    workMap = factory.get(conf);
    assertEquals("FIX VERIFIED: After remove, should get fresh empty Map", 0, workMap.size());
  }

  /**
   * 线程池复用场景下的泄漏复现（模拟 HS2 线程池）。
   *
   * 使用固定线程池(2线程)执行 20 次"查询"，验证线程复用时 Map 的积累行为。
   */
  @Test
  public void testLeakInThreadPool() throws Exception {
    ExecutorService pool = Executors.newFixedThreadPool(2);
    AtomicInteger maxMapSize = new AtomicInteger(0);

    CountDownLatch latch = new CountDownLatch(20);
    for (int q = 0; q < 20; q++) {
      final int queryId = q;
      pool.submit(() -> {
        try {
          // 每个线程需要独立的 SessionState
          SessionState ss = new SessionState(conf);
          SessionState.setCurrentSessionState(ss);
          ss.setIsHiveServerQuery(true);

          Map<Path, BaseWork> workMap = factory.get(conf);
          for (int i = 0; i < 5; i++) {
            workMap.put(new Path("/tmp/q" + queryId + "/s" + i), new MapWork());
          }

          // 记录当前线程 Map 大小
          int size = workMap.size();
          maxMapSize.updateAndGet(current -> Math.max(current, size));

          // 不调用 clear — 模拟 bug
        } finally {
          SessionState.detachSession();
          latch.countDown();
        }
      });
    }

    latch.await(30, TimeUnit.SECONDS);
    pool.shutdown();

    // 2 个线程各执行 10 次查询，每次 5 个条目
    // 最终每个线程的 Map 应有 50 个条目（泄漏）
    assertTrue("BUG REPRODUCED: Thread pool reuse causes Map accumulation, max size = " + maxMapSize.get(),
        maxMapSize.get() > 5);
  }

  /**
   * 线程池复用场景下修复验证。
   */
  @Test
  public void testFixInThreadPool() throws Exception {
    ExecutorService pool = Executors.newFixedThreadPool(2);
    AtomicInteger maxMapSize = new AtomicInteger(0);

    CountDownLatch latch = new CountDownLatch(20);
    for (int q = 0; q < 20; q++) {
      final int queryId = q;
      pool.submit(() -> {
        try {
          SessionState ss = new SessionState(conf);
          SessionState.setCurrentSessionState(ss);
          ss.setIsHiveServerQuery(true);

          Map<Path, BaseWork> workMap = factory.get(conf);
          for (int i = 0; i < 5; i++) {
            workMap.put(new Path("/tmp/q" + queryId + "/s" + i), new MapWork());
          }

          // [FIX] 查询结束后清理
          factory.clearThreadLocalWorkMap();

          // 验证清理后大小
          int size = factory.get(conf).size();
          maxMapSize.updateAndGet(current -> Math.max(current, size));
        } finally {
          SessionState.detachSession();
          latch.countDown();
        }
      });
    }

    latch.await(30, TimeUnit.SECONDS);
    pool.shutdown();

    assertEquals("FIX VERIFIED: After clear in thread pool, Map should always be empty",
        0, maxMapSize.get());
  }
}
