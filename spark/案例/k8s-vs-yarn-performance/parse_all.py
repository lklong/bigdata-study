#!/usr/bin/env python3
"""统一解析所有 Spark Event Log，提取核心指标，输出 JSON 供对比"""
import json, sys, os, statistics
from collections import defaultdict
from datetime import datetime

def parse_event_log(filepath):
    r = {'app_name':'','app_id':'','spark_version':'','driver_host':'',
         'start_time':None,'end_time':None,'jobs':[],'stages':[],'tasks':[],
         'executors':{},'config':{},'hadoop_config':{}}
    with open(filepath,'r') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: e = json.loads(line)
            except: continue
            ev = e.get('Event','')
            if ev == 'SparkListenerLogStart':
                r['spark_version'] = e.get('Spark Version','')
            elif ev == 'SparkListenerApplicationStart':
                r['app_name'] = e.get('App Name','')
                r['app_id'] = e.get('App ID','')
                r['start_time'] = e.get('Timestamp',0)
            elif ev == 'SparkListenerApplicationEnd':
                r['end_time'] = e.get('Timestamp',0)
            elif ev == 'SparkListenerEnvironmentUpdate':
                r['config'] = e.get('Spark Properties',{})
                r['hadoop_config'] = e.get('Hadoop Properties',{})
                r['driver_host'] = r['config'].get('spark.driver.host','')
            elif ev == 'SparkListenerJobStart':
                r['jobs'].append({'job_id':e.get('Job ID'),'start_time':e.get('Submission Time',0),
                    'stage_ids':e.get('Stage IDs',[]),'props':e.get('Properties',{})})
            elif ev == 'SparkListenerJobEnd':
                jid = e.get('Job ID'); et = e.get('Completion Time',0)
                st = e.get('Job Result',{}).get('Result','Unknown')
                for j in r['jobs']:
                    if j['job_id']==jid:
                        j['end_time']=et; j['status']=st
                        j['duration_ms']=et-j['start_time'] if et and j['start_time'] else 0
            elif ev == 'SparkListenerStageCompleted':
                si = e.get('Stage Info',{})
                s = {'stage_id':si.get('Stage ID'),'stage_name':si.get('Stage Name','')[:80],
                     'num_tasks':si.get('Number of Tasks',0),
                     'submission_time':si.get('Submission Time',0),
                     'completion_time':si.get('Completion Time',0),
                     'status':si.get('Stage Status',''), 'metrics':{}}
                s['duration_ms'] = s['completion_time']-s['submission_time'] if s['completion_time'] and s['submission_time'] else 0
                for acc in si.get('Accumulables',[]):
                    s['metrics'][acc.get('Name','')] = acc.get('Value',0)
                r['stages'].append(s)
            elif ev == 'SparkListenerTaskEnd':
                ti = e.get('Task Info',{}); tm = e.get('Task Metrics',{})
                if not tm: continue
                sr = tm.get('Shuffle Read Metrics',{}); sw = tm.get('Shuffle Write Metrics',{})
                im = tm.get('Input Metrics',{}); om = tm.get('Output Metrics',{})
                t = {
                    'stage_id':e.get('Stage ID'),
                    'duration_ms':ti.get('Finish Time',0)-ti.get('Launch Time',0),
                    'executor_run_time':tm.get('Executor Run Time',0),
                    'executor_cpu_time':tm.get('Executor CPU Time',0),
                    'jvm_gc_time':tm.get('JVM GC Time',0),
                    'deser_time':tm.get('Executor Deserialize Time',0),
                    'result_ser_time':tm.get('Result Serialization Time',0),
                    'shuffle_read_bytes':sr.get('Remote Bytes Read',0)+sr.get('Local Bytes Read',0),
                    'shuffle_remote_bytes':sr.get('Remote Bytes Read',0),
                    'shuffle_local_bytes':sr.get('Local Bytes Read',0),
                    'shuffle_fetch_wait':sr.get('Fetch Wait Time',0),
                    'shuffle_write_bytes':sw.get('Shuffle Bytes Written',0),
                    'shuffle_write_time_ns':sw.get('Shuffle Write Time',0),
                    'input_bytes':im.get('Bytes Read',0),
                    'input_records':im.get('Records Read',0),
                    'output_bytes':om.get('Bytes Written',0),
                    'mem_spill':tm.get('Memory Bytes Spilled',0),
                    'disk_spill':tm.get('Disk Bytes Spilled',0),
                    'peak_mem':tm.get('Peak Execution Memory',0),
                    'failed':ti.get('Failed',False),
                    'speculative':ti.get('Speculative',False),
                }
                r['tasks'].append(t)
            elif ev == 'SparkListenerExecutorAdded':
                eid = e.get('Executor ID','')
                ei = e.get('Executor Info',{})
                r['executors'][eid] = {'host':ei.get('Host',''),'cores':ei.get('Total Cores',0),
                    'added':e.get('Timestamp',0),'removed':None}
            elif ev == 'SparkListenerExecutorRemoved':
                eid = e.get('Executor ID','')
                if eid in r['executors']:
                    r['executors'][eid]['removed'] = e.get('Timestamp',0)
                    r['executors'][eid]['reason'] = e.get('Removed Reason','')
    return r

def hb(n):
    if not n: return '0 B'
    for u in ['B','KB','MB','GB','TB']:
        if abs(n)<1024: return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"

def ht(ms):
    if not ms: return '0ms'
    if ms<1000: return f"{ms:.0f}ms"
    if ms<60000: return f"{ms/1000:.1f}s"
    if ms<3600000: return f"{ms/60000:.1f}min"
    return f"{ms/3600000:.2f}h"

def stats(vals):
    if not vals: return {k:0 for k in ['min','max','avg','p50','p90','p95','p99','sum','count','stdev']}
    s = sorted(vals); n = len(s)
    return {'min':s[0],'max':s[-1],'avg':sum(s)/n,'p50':s[n//2],'p90':s[int(n*.9)],
            'p95':s[int(n*.95)],'p99':s[int(n*.99)],'sum':sum(s),'count':n,
            'stdev':statistics.stdev(s) if n>1 else 0}

def summarize(data, label):
    total_dur = (data['end_time']-data['start_time']) if data['start_time'] and data['end_time'] else 0
    tasks = data['tasks']
    ts = stats([t['duration_ms'] for t in tasks])
    rs = stats([t['executor_run_time'] for t in tasks])
    gs = stats([t['jvm_gc_time'] for t in tasks])
    cs = stats([t['executor_cpu_time']/1e6 for t in tasks])
    srs = stats([t['shuffle_read_bytes'] for t in tasks])
    sws = stats([t['shuffle_write_bytes'] for t in tasks])
    sfs = stats([t['shuffle_fetch_wait'] for t in tasks])
    ibs = stats([t['input_bytes'] for t in tasks])
    obs = stats([t['output_bytes'] for t in tasks])
    mss = stats([t['mem_spill'] for t in tasks])
    dss = stats([t['disk_spill'] for t in tasks])
    pms = stats([t['peak_mem'] for t in tasks])
    ds = stats([t['deser_time'] for t in tasks])

    total_run = sum(t['executor_run_time'] for t in tasks)
    total_gc = sum(t['jvm_gc_time'] for t in tasks)
    total_cpu = sum(t['executor_cpu_time']/1e6 for t in tasks)
    gc_pct = (total_gc/total_run*100) if total_run else 0
    cpu_pct = (total_cpu/total_run*100*1000) if total_run else 0  # cpu is in ms already
    
    total_sr = sum(t['shuffle_remote_bytes'] for t in tasks)
    total_sl = sum(t['shuffle_local_bytes'] for t in tasks)
    total_sh = total_sr+total_sl
    remote_pct = (total_sr/total_sh*100) if total_sh else 0

    failed = sum(1 for t in tasks if t['failed'])
    spec = sum(1 for t in tasks if t['speculative'])

    # Platform detection
    cfg = data['config']
    platform = 'K8s' if 'spark.kubernetes.namespace' in cfg else 'YARN'
    shuffle_mgr = cfg.get('spark.shuffle.manager','default')
    if 'celeborn' in shuffle_mgr.lower(): shuffle_type = 'Celeborn'
    elif 'css' in shuffle_mgr.lower(): shuffle_type = 'CSS'
    else: shuffle_type = 'Built-in'
    
    # COS impl
    cosn_impl_spark = cfg.get('spark.hadoop.fs.cosn.impl','')
    cosn_impl_hadoop = data['hadoop_config'].get('fs.cosn.impl','')
    cosn_impl = cosn_impl_spark or cosn_impl_hadoop or 'default'
    
    read_ahead = cfg.get('spark.hadoop.fs.cosn.read.ahead.block.size', 
                         data['hadoop_config'].get('fs.cosn.read.ahead.block.size','N/A'))
    
    # Start time human
    start_str = datetime.fromtimestamp(data['start_time']/1000).strftime('%Y-%m-%d %H:%M:%S') if data['start_time'] else 'N/A'
    end_str = datetime.fromtimestamp(data['end_time']/1000).strftime('%Y-%m-%d %H:%M:%S') if data['end_time'] else 'N/A'

    # Job SQL desc
    sql_desc = ''
    for j in data['jobs']:
        d = j.get('props',{}).get('spark.job.description','')
        if 'SELECT' in d or 'FROM' in d:
            sql_desc = d[:200]
            break

    return {
        'label': label, 'platform': platform,
        'app_name': data['app_name'], 'app_id': data['app_id'],
        'spark_version': data['spark_version'],
        'start_time': start_str, 'end_time': end_str,
        'total_duration_ms': total_dur, 'total_duration_h': ht(total_dur),
        'num_executors': len(data['executors']),
        'executor_memory': cfg.get('spark.executor.memory','N/A'),
        'executor_cores': cfg.get('spark.executor.cores','N/A'),
        'executor_overhead': cfg.get('spark.executor.memoryOverhead','N/A'),
        'driver_memory': cfg.get('spark.driver.memory','N/A'),
        'max_executors': cfg.get('spark.dynamicAllocation.maxExecutors','N/A'),
        'min_executors': cfg.get('spark.dynamicAllocation.minExecutors','N/A'),
        'shuffle_partitions': cfg.get('spark.sql.shuffle.partitions','N/A'),
        'max_partition_bytes': cfg.get('spark.sql.files.maxPartitionBytes','N/A'),
        'shuffle_manager': shuffle_type,
        'cosn_impl': cosn_impl.split('.')[-1],
        'read_ahead_block': read_ahead,
        'num_jobs': len(data['jobs']),
        'num_stages': len(data['stages']),
        'num_tasks': len(tasks),
        'failed_tasks': failed, 'speculative_tasks': spec,
        'task_dur': ts, 'run_time': rs, 'gc_time': gs, 'cpu_time_ms': cs,
        'shuffle_read': srs, 'shuffle_write': sws, 'shuffle_fetch': sfs,
        'input_bytes': ibs, 'output_bytes': obs,
        'mem_spill': mss, 'disk_spill': dss, 'peak_mem': pms, 'deser': ds,
        'gc_pct': gc_pct, 'remote_pct': remote_pct,
        'total_run_h': ht(total_run), 'total_gc_h': ht(total_gc),
        'total_cpu_ms_h': ht(total_cpu),
        'total_input': hb(ibs['sum']), 'total_output': hb(obs['sum']),
        'total_shuffle_read': hb(srs['sum']), 'total_shuffle_write': hb(sws['sum']),
        'total_spill_mem': hb(mss['sum']), 'total_spill_disk': hb(dss['sum']),
        'skew_ratio': ts['max']/ts['p50'] if ts['p50'] else 0,
        'sql_desc': sql_desc,
        'jobs': [{'id':j['job_id'],'dur':ht(j.get('duration_ms',0)),'dur_ms':j.get('duration_ms',0),
                  'status':j.get('status','?'),'stages':j.get('stage_ids',[])} for j in data['jobs']],
        'stages': [{'id':s['stage_id'],'name':s['stage_name'],'tasks':s['num_tasks'],
                    'dur':ht(s['duration_ms']),'dur_ms':s['duration_ms']} for s in sorted(data['stages'],key=lambda x:x['stage_id'])],
        'java_version': '',
        'region': cfg.get('spark.hadoop.fs.cos.userinfo.region', data['hadoop_config'].get('fs.cos.userinfo.region','N/A')),
    }

# Parse all event logs
base = '/Users/kailongliu/CodeBuddy/20260414234857'
event_logs = [
    (f'{base}/analysis/yarn/application_1760404906372_12173904_1', 'YARN (4/7)'),
    (f'{base}/analysis/yarn/spark-171a31c6376f48eaa12419a96b8fb9f5', 'K8s-old (4/7)'),
    (f'{base}/k8s-logs/spark-event-d87771f211c54a1fa442c30c9be4a5a1', 'K8s-d877 (4/14 早)'),
    (f'{base}/k8s-logs/spark-event-5c994d5498544f2aac19499953539402', 'K8s-5c99 (4/14 晚)'),
]

results = []
for path, label in event_logs:
    print(f'解析 {label} ...', file=sys.stderr)
    data = parse_event_log(path)
    s = summarize(data, label)
    results.append(s)

# Print comparison table
print(f"\n{'='*120}")
print(f"  全量 Spark 应用执行情况对比（YARN vs K8s）")
print(f"{'='*120}\n")

labels = [r['label'] for r in results]
header = f"{'指标':35s}" + ''.join(f"{l:>22s}" for l in labels)
print(header)
print('-'*len(header))

def row(name, vals, fmt='str'):
    parts = [f"{name:35s}"]
    for v in vals:
        if fmt=='time': parts.append(f"{ht(v):>22s}")
        elif fmt=='bytes': parts.append(f"{hb(v):>22s}")
        elif fmt=='pct': parts.append(f"{v:>21.2f}%")
        elif fmt=='num': parts.append(f"{v:>22,}")
        else: parts.append(f"{str(v):>22s}")
    print(''.join(parts))

row('Platform', [r['platform'] for r in results])
row('App Name', [r['app_name'][:20] for r in results])
row('Start Time', [r['start_time'] for r in results])
row('End Time', [r['end_time'] for r in results])
row('Total Duration', [r['total_duration_ms'] for r in results], 'time')
row('Executors', [r['num_executors'] for r in results], 'num')
row('Executor Memory', [r['executor_memory'] for r in results])
row('Executor Cores', [r['executor_cores'] for r in results])
row('Shuffle Manager', [r['shuffle_manager'] for r in results])
row('COS Impl', [r['cosn_impl'] for r in results])
row('Read Ahead Block', [str(r['read_ahead_block']) for r in results])
row('Region', [r['region'] for r in results])
row('Jobs', [r['num_jobs'] for r in results], 'num')
row('Stages', [r['num_stages'] for r in results], 'num')
row('Tasks', [r['num_tasks'] for r in results], 'num')
row('Failed Tasks', [r['failed_tasks'] for r in results], 'num')
row('Speculative Tasks', [r['speculative_tasks'] for r in results], 'num')
print()
row('Task Duration avg', [r['task_dur']['avg'] for r in results], 'time')
row('Task Duration p50', [r['task_dur']['p50'] for r in results], 'time')
row('Task Duration p90', [r['task_dur']['p90'] for r in results], 'time')
row('Task Duration p99', [r['task_dur']['p99'] for r in results], 'time')
row('Task Duration max', [r['task_dur']['max'] for r in results], 'time')
print()
row('Executor RunTime total', [r['total_run_h'] for r in results])
row('CPU Time total', [r['total_cpu_ms_h'] for r in results])
row('GC Time total', [r['total_gc_h'] for r in results])
row('GC %', [r['gc_pct'] for r in results], 'pct')
row('GC avg', [r['gc_time']['avg'] for r in results], 'time')
row('GC p99', [r['gc_time']['p99'] for r in results], 'time')
row('GC max', [r['gc_time']['max'] for r in results], 'time')
print()
row('Input Bytes total', [r['input_bytes']['sum'] for r in results], 'bytes')
row('Input avg/task', [r['input_bytes']['avg'] for r in results], 'bytes')
row('Output Bytes total', [r['output_bytes']['sum'] for r in results], 'bytes')
row('Shuffle Read total', [r['shuffle_read']['sum'] for r in results], 'bytes')
row('Shuffle Write total', [r['shuffle_write']['sum'] for r in results], 'bytes')
row('Shuffle Fetch Wait avg', [r['shuffle_fetch']['avg'] for r in results], 'time')
row('Shuffle Remote %', [r['remote_pct'] for r in results], 'pct')
print()
row('Memory Spill total', [r['mem_spill']['sum'] for r in results], 'bytes')
row('Disk Spill total', [r['disk_spill']['sum'] for r in results], 'bytes')
row('Peak Exec Memory avg', [r['peak_mem']['avg'] for r in results], 'bytes')
row('Deserialize avg', [r['deser']['avg'] for r in results], 'time')
row('Skew ratio (max/p50)', [r['skew_ratio'] for r in results], 'pct')

# Job-level comparison
print(f"\n{'='*120}")
print(f"  Job 级别对比")
print(f"{'='*120}\n")
max_jobs = max(r['num_jobs'] for r in results)
for jid in range(max_jobs):
    parts = [f"{'Job '+str(jid):35s}"]
    for r in results:
        if jid < len(r['jobs']):
            j = r['jobs'][jid]
            parts.append(f"{j['dur']+' ('+j['status'][:4]+')':>22s}")
        else:
            parts.append(f"{'N/A':>22s}")
    print(''.join(parts))

# Stage-level comparison
print(f"\n{'='*120}")
print(f"  Stage 级别对比")
print(f"{'='*120}\n")
all_sids = sorted(set(s['id'] for r in results for s in r['stages']))
for sid in all_sids:
    parts = [f"{'Stage '+str(sid):35s}"]
    for r in results:
        matched = [s for s in r['stages'] if s['id']==sid]
        if matched:
            s = matched[0]
            parts.append(f"{s['dur']+'('+str(s['tasks'])+'t)':>22s}")
        else:
            parts.append(f"{'N/A':>22s}")
    print(''.join(parts))

# SQL info
print(f"\n{'='*120}")
print(f"  SQL 信息")
print(f"{'='*120}\n")
for r in results:
    print(f"  {r['label']}: {r['sql_desc'][:150] if r['sql_desc'] else 'N/A'}")
