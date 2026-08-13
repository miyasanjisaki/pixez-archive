import 'package:flutter/material.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/novel/component/novel_lighting_list.dart';
import 'package:pixez/utils/haptic_util.dart';

class NovelRankPage extends StatefulWidget {
  final bool embedded;

  const NovelRankPage({super.key, this.embedded = false});

  @override
  State<NovelRankPage> createState() => _NovelRankPageState();
}

class _NovelRankPageState extends State<NovelRankPage>
    with AutomaticKeepAliveClientMixin {
  final modeList = [
    "day",
    "day_male",
    "day_female",
    "week",
    "week_ai",
    "week_ai_r18",
    "day_r18",
    "week_r18",
    "week_r18g",
  ];
  String? toRequestDate(DateTime dateTime) {
    return "${dateTime.year}-${dateTime.month}-${dateTime.day}";
  }

  String? dateTime;
  DateTime nowDateTime = DateTime.now();

  Future<void> _selectDate() async {
    final date = await showDatePicker(
                    context: context,
                    initialDate: nowDateTime,
                    locale: userSetting.locale,
                    firstDate: DateTime(2007, 8),
      lastDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
                  setState(() {
      nowDateTime = date;
      dateTime = toRequestDate(date);
                  });
                }

  Widget _buildModeTabs(List<String> labels) {
    return TabBar(
      onTap: (_) => HapticUtil.selectionClick(),
      indicatorSize: TabBarIndicatorSize.label,
      isScrollable: true,
      tabs: [for (final label in labels) Tab(text: label)],
    );
  }

  Widget _buildDateButton() {
    return IconButton(
      tooltip: MaterialLocalizations.of(context).dateRangePickerHelpText,
      icon: const Icon(Icons.date_range),
      onPressed: _selectDate,
    );
  }

  Widget _buildResults() {
    return TabBarView(
      children: [
        for (final mode in modeList)
          NovelLightingList(
            futureGet: () => apiClient.getNovelRanking(mode, dateTime),
            ),
          ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final labels = I18n.of(context).novel_mode_list.split(" ");
    return DefaultTabController(
      length: modeList.length,
      child: widget.embedded
          ? Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Row(
                    children: [
                      Expanded(child: _buildModeTabs(labels)),
                      _buildDateButton(),
                    ],
        ),
                ),
                Expanded(child: _buildResults()),
              ],
            )
          : Scaffold(
              appBar: AppBar(
                title: _buildModeTabs(labels),
                actions: [_buildDateButton()],
              ),
              body: _buildResults(),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
