import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';

class LumaSyncScreen extends StatefulWidget {
  const LumaSyncScreen({super.key});

  @override
  State<LumaSyncScreen> createState() => _LumaSyncScreenState();
}

class _LumaSyncScreenState extends State<LumaSyncScreen> {
  final ApiService _api = ApiService();

  // 时间段选择（必须指定）
  DateTime? _startDate;
  DateTime? _endDate;

  // 地点多选
  final Set<String> _selectedLocations = {'san_francisco', 'berkeley', 'shanghai'};

  final Map<String, String> _locationLabels = {
    'san_francisco': '旧金山 (SF)',
    'berkeley': '伯克利 (Berkeley)',
    'shanghai': '上海 (Shanghai)',
  };

  // 任务状态
  bool _isTaskRunning = false;
  String _taskStatus = 'idle'; // 'idle', 'running', 'completed', 'error'
  double _progress = 0.0;
  int _totalScanned = 0;
  int _newAdded = 0;
  int _skippedCount = 0;
  int _vaultTotal = 0;
  int _lastSyncTime = 0;
  String _currentCity = '';
  String _taskMessage = '尚未发起同步任务';
  String? _error;

  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    // 默认预设为未来 1 个月，用户可自由更改
    final now = DateTime.now();
    _startDate = now;
    _endDate = now.add(const Duration(days: 30));
    _fetchInitialStatus();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  Future<void> _fetchInitialStatus() async {
    try {
      final res = await _api.getLumaVaultSyncStatus();
      if (!mounted) return;
      setState(() {
        _taskStatus = res['status'] ?? 'idle';
        _isTaskRunning = _taskStatus == 'running';
        _progress = (res['progress'] as num?)?.toDouble() ?? 0.0;
        _totalScanned = res['totalScanned'] ?? 0;
        _newAdded = res['newAdded'] ?? 0;
        _skippedCount = res['skippedCount'] ?? 0;
        _vaultTotal = res['vaultTotal'] ?? 0;
        _lastSyncTime = res['lastSyncTime'] ?? 0;
        _currentCity = res['currentCity'] ?? '';
        _taskMessage = res['message'] ?? '准备就绪';
      });

      if (_isTaskRunning) {
        _startPolling();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _taskMessage = '获取状态失败: $e';
        });
      }
    }
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 1200), (timer) async {
      try {
        final res = await _api.getLumaVaultSyncStatus();
        if (!mounted) return;

        final status = res['status'] ?? 'idle';
        final isRunning = status == 'running';

        setState(() {
          _taskStatus = status;
          _isTaskRunning = isRunning;
          _progress = (res['progress'] as num?)?.toDouble() ?? 0.0;
          _totalScanned = res['totalScanned'] ?? 0;
          _newAdded = res['newAdded'] ?? 0;
          _skippedCount = res['skippedCount'] ?? 0;
          _vaultTotal = res['vaultTotal'] ?? 0;
          _lastSyncTime = res['lastSyncTime'] ?? 0;
          _currentCity = res['currentCity'] ?? '';
          _taskMessage = res['message'] ?? '';
          if (res['error'] != null) {
            _error = res['error'];
          }
        });

        if (!isRunning) {
          timer.cancel();
        }
      } catch (e) {
        // Polling retry
      }
    });
  }

  Future<void> _startSyncTask() async {
    if (_startDate == null || _endDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('必须指定同步时间段（请选择开始与结束日期）')),
      );
      return;
    }

    if (_selectedLocations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少选择一个同步城市')),
      );
      return;
    }

    final startStr = DateFormat('MM:dd:yy').format(_startDate!);
    final endStr = DateFormat('MM:dd:yy').format(_endDate!);

    setState(() {
      _isTaskRunning = true;
      _taskStatus = 'running';
      _progress = 0.05;
      _totalScanned = 0;
      _newAdded = 0;
      _skippedCount = 0;
      _taskMessage = '正在启动同步任务...';
      _error = null;
    });

    try {
      final res = await _api.startLumaVaultSync(
        startDate: startStr,
        endDate: endStr,
        locations: _selectedLocations.toList(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('异步同步任务已启动，正在后台抓取并写入 Vault')),
        );
        _startPolling();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isTaskRunning = false;
          _taskStatus = 'error';
          _error = e.toString();
          _taskMessage = '启动失败: $e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('启动同步失败: $e')),
        );
      }
    }
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      helpText: '选择同步起始日期',
    );
    if (picked != null) {
      setState(() {
        _startDate = picked;
        if (_endDate != null && _endDate!.isBefore(_startDate!)) {
          _endDate = _startDate!.add(const Duration(days: 30));
        }
      });
    }
  }

  Future<void> _pickEndDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? (_startDate?.add(const Duration(days: 30)) ?? now),
      firstDate: _startDate ?? DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      helpText: '选择同步结束日期',
    );
    if (picked != null) {
      setState(() {
        _endDate = picked;
      });
    }
  }

  void _applyQuickRange(int days) {
    final now = DateTime.now();
    setState(() {
      _startDate = now;
      _endDate = now.add(Duration(days: days));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Luma Vault 手动同步'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_outlined),
            tooltip: '刷新状态',
            onPressed: _isTaskRunning ? null : _fetchInitialStatus,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          // 头部说明卡片
          Card(
            elevation: 0,
            color: isDark ? const Color(0xFF1B2B3A) : const Color(0xFFEBF3FB),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isDark ? const Color(0xFF284664) : const Color(0xFFC7DEF5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: primaryColor, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Vault 增量抓取与自动入库',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '指定时间段后，系统将自动向后翻页抓取所有活动并存入 Luma Vault，自动生成高维向量嵌入。已存入 Vault 的活动将自动跳过，不重复下载。',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? Colors.white70 : Colors.black54,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 核心表单卡片：时间段选择（必选）
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isDark ? Colors.white12 : Colors.grey.shade300,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.date_range_outlined, color: primaryColor, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        '必须指定同步时间段',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        '(必填)',
                        style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 日期选择行
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: _isTaskRunning ? null : _pickStartDate,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: _startDate != null ? primaryColor : Colors.grey.shade400,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              color: isDark ? Colors.white.withOpacity(0.04) : Colors.grey.shade50,
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.event, size: 18, color: primaryColor),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        '起始时间',
                                        style: TextStyle(fontSize: 11, color: Colors.grey),
                                      ),
                                      Text(
                                        _startDate != null
                                            ? DateFormat('yyyy-MM-dd').format(_startDate!)
                                            : '点击选择起始时间',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w500,
                                          fontSize: 14,
                                          color: _startDate != null ? null : Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          onTap: _isTaskRunning ? null : _pickEndDate,
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: _endDate != null ? primaryColor : Colors.grey.shade400,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              color: isDark ? Colors.white.withOpacity(0.04) : Colors.grey.shade50,
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.event, size: 18, color: primaryColor),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        '截止时间',
                                        style: TextStyle(fontSize: 11, color: Colors.grey),
                                      ),
                                      Text(
                                        _endDate != null
                                            ? DateFormat('yyyy-MM-dd').format(_endDate!)
                                            : '点击选择截止时间',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w500,
                                          fontSize: 14,
                                          color: _endDate != null ? null : Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 快捷时间段 Chips
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ActionChip(
                        label: const Text('未来 1 个月'),
                        onPressed: _isTaskRunning ? null : () => _applyQuickRange(30),
                      ),
                      ActionChip(
                        label: const Text('未来 2 个月'),
                        onPressed: _isTaskRunning ? null : () => _applyQuickRange(60),
                      ),
                      ActionChip(
                        label: const Text('未来 3 个月'),
                        onPressed: _isTaskRunning ? null : () => _applyQuickRange(90),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 城市多选
                  Row(
                    children: [
                      Icon(Icons.location_on_outlined, color: primaryColor, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        '选择同步城市',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _locationLabels.entries.map((e) {
                      final selected = _selectedLocations.contains(e.key);
                      return FilterChip(
                        label: Text(e.value),
                        selected: selected,
                        onSelected: _isTaskRunning
                            ? null
                            : (val) {
                                setState(() {
                                  if (val) {
                                    _selectedLocations.add(e.key);
                                  } else {
                                    if (_selectedLocations.length > 1) {
                                      _selectedLocations.remove(e.key);
                                    }
                                  }
                                });
                              },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),

                  // 启动按钮
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: (_isTaskRunning || _startDate == null || _endDate == null)
                          ? null
                          : _startSyncTask,
                      icon: _isTaskRunning
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.cloud_sync_outlined),
                      label: Text(
                        _isTaskRunning ? '同步任务进行中...' : '开始抓取并存入 Vault',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 任务进度与实时统计卡片
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isDark ? Colors.white12 : Colors.grey.shade300,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.stream, color: primaryColor, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            '实时同步进度',
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _taskStatus == 'completed'
                              ? Colors.green.withOpacity(0.12)
                              : (_taskStatus == 'running'
                                  ? primaryColor.withOpacity(0.12)
                                  : Colors.grey.withOpacity(0.12)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _taskStatus == 'completed'
                              ? '已完成'
                              : (_taskStatus == 'running' ? '同步中 (${(_progress * 100).toInt()}%)' : '就绪'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _taskStatus == 'completed'
                                ? Colors.green
                                : (_taskStatus == 'running' ? primaryColor : Colors.grey),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // 进度条
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: _isTaskRunning
                          ? (_progress > 0 ? _progress : null)
                          : (_taskStatus == 'completed' ? 1.0 : 0.0),
                      minHeight: 8,
                      backgroundColor: isDark ? Colors.white10 : Colors.grey.shade200,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 状态信息描述
                  Text(
                    _taskMessage,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white70 : Colors.black87,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 4 格指标卡片
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricCard(
                          label: '已扫描活动',
                          value: '$_totalScanned',
                          color: isDark ? Colors.white : Colors.black87,
                          isDark: isDark,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricCard(
                          label: '新增入库',
                          value: '+$_newAdded',
                          color: Colors.green,
                          isDark: isDark,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricCard(
                          label: '跳过已存',
                          value: '$_skippedCount',
                          color: Colors.orangeAccent,
                          isDark: isDark,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricCard(
                          label: '当前城市',
                          value: _currentCity.isNotEmpty ? _currentCity : '旧金山',
                          color: primaryColor,
                          isDark: isDark,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Vault 全局状态卡片
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: isDark ? Colors.white12 : Colors.grey.shade300,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.inventory_2_outlined, color: primaryColor, size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'Luma Public Vault 概况',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('当前 Vault 活动总节点数', style: TextStyle(fontSize: 13, color: Colors.grey)),
                      Text(
                        '$_vaultTotal 个活动',
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('上次同步完成时间', style: TextStyle(fontSize: 13, color: Colors.grey)),
                      Text(
                        _lastSyncTime > 0
                            ? DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(_lastSyncTime))
                            : '暂无记录',
                        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('后台自动轮询机制', style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const Text('每小时自动全量增量更新', style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildMetricCard({
    required String label,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.04) : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.grey.shade200,
        ),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
