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

import java.util.Collection;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

import org.apache.hadoop.conf.Configuration;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.hive.conf.HiveConf;
import org.apache.hadoop.hive.conf.HiveConf.ConfVars;
import org.apache.hadoop.hive.ql.plan.BaseWork;
import org.apache.hadoop.hive.ql.session.SessionState;
import org.apache.hadoop.hive.llap.io.api.LlapProxy;

/**
 * [FIX] OHL-001: 修复 ThreadLocal<Map<Path, BaseWork>> 无限增长问题。
 *
 * 根因: 在 HiveServerQuery 模式下，每次查询 put 进 ThreadLocal Map 但从不 remove/clear，
 *       HS2 线程池复用线程导致 Map 只增不减，BaseWork (数十MB级) 持续积累直到 OOM。
 *
 * 修复原理: 新增 clearThreadLocalWorkMap() 方法，在查询生命周期结束时由 Driver 调用清理。
 *           同时提供 remove() 方法支持完整释放 ThreadLocal 引用。
 *
 * 影响版本: Hive 2.3.x, Hive 3.x (所有版本均受影响，trunk 截至当前未修复)
 */
public class GlobalWorkMapFactory {

  private ThreadLocal<Map<Path, BaseWork>> threadLocalWorkMap = null;

  private Map<Path, BaseWork> gWorkMap = null;

  private static class DummyMap<K, V> implements Map<K, V> {
    @Override
    public void clear() {
    }

    @Override
    public boolean containsKey(final Object key) {
      return false;
    }

    @Override
    public boolean containsValue(final Object value) {
      return false;
    }

    @Override
    public Set<Map.Entry<K, V>> entrySet() {
      return null;
    }

    @Override
    public V get(final Object key) {
      return null;
    }

    @Override
    public boolean isEmpty() {
      return false;
    }

    @Override
    public Set<K> keySet() {
      return null;
    }

    @Override
    public V put(final K key, final V value) {
      return null;
    }

    @Override
    public void putAll(final Map<? extends K, ? extends V> t) {
    }

    @Override
    public V remove(final Object key) {
      return null;
    }

    @Override
    public int size() {
      return 0;
    }

    @Override
    public Collection<V> values() {
      return null;
    }
  }

  DummyMap<Path, BaseWork> dummy = new DummyMap<Path, BaseWork>();

  public Map<Path, BaseWork> get(Configuration conf) {
    if (LlapProxy.isDaemon()
        || (SessionState.get() != null && SessionState.get().isHiveServerQuery())) {
      if (threadLocalWorkMap == null) {
        threadLocalWorkMap = new ThreadLocal<Map<Path, BaseWork>>() {
          @Override
          protected Map<Path, BaseWork> initialValue() {
            return new HashMap<Path, BaseWork>();
          }
        };
      }
      return threadLocalWorkMap.get();
    }

    if (gWorkMap == null) {
      gWorkMap = new HashMap<Path, BaseWork>();
    }
    return gWorkMap;
  }

  // ====== BEGIN FIX ======

  /**
   * 清理当前线程 ThreadLocal 中的 WorkMap 内容。
   * 应在每次查询执行完毕后（Driver.releaseResources()）调用。
   *
   * 这是首选方法: clear() 只清空 Map 内容但保留 ThreadLocal 引用，
   * 避免下次查询重新创建 HashMap 的开销。
   */
  public void clearThreadLocalWorkMap() {
    if (threadLocalWorkMap != null) {
      Map<Path, BaseWork> map = threadLocalWorkMap.get();
      if (map != null) {
        map.clear();
      }
    }
  }

  /**
   * 彻底移除当前线程的 ThreadLocal 条目。
   * 适用于线程退出或需要完整释放引用的场景。
   */
  public void removeThreadLocalWorkMap() {
    if (threadLocalWorkMap != null) {
      threadLocalWorkMap.remove();
    }
  }

  // ====== END FIX ======

}
