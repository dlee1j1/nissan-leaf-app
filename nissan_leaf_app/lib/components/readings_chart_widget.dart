import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../data/reading_model.dart';

class ReadingsChartWidget extends StatefulWidget {
  final List<Reading> readings;
  final bool isLoading;
  final String title;
  final Color lineColor;
  final String yAxisTitle;
  final double Function(Reading) dataSelector;

  /// A time series chart that displays readings data
  ///
  /// By default, it shows the state of charge, but can be configured
  /// to show any numerical data from Reading objects using the dataSelector
  const ReadingsChartWidget({
    super.key,
    required this.readings,
    this.isLoading = false,
    this.title = 'Battery Charge History',
    this.lineColor = Colors.blue,
    this.yAxisTitle = 'Charge (%)',
    this.dataSelector = _defaultDataSelector,
  });

  static double _defaultDataSelector(Reading reading) => reading.stateOfCharge;

  @override
  State<ReadingsChartWidget> createState() => _ReadingsChartWidgetState();
}

class _ReadingsChartWidgetState extends State<ReadingsChartWidget> {
  int? selectedSpotIndex;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (widget.isLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(40.0),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (widget.readings.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(40.0),
                  child: Column(
                    children: [
                      Icon(Icons.bar_chart, size: 48, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        'No data available',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.grey[600],
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Connect to your vehicle to collect readings',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              SizedBox(
                height: 250,
                child: _buildChart(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart() {
    final sortedReadings = List<Reading>.from(widget.readings)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return Padding(
      padding: const EdgeInsets.only(right: 16.0, top: 16.0),
      child: LineChart(
        LineChartData(
          gridData: FlGridData(
            horizontalInterval: 20,
            getDrawingHorizontalLine: (value) {
              return FlLine(
                color: Color.fromRGBO(128, 128, 128, 0.3),
                strokeWidth: 1,
              );
            },
          ),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  if (value.toInt() >= sortedReadings.length || value < 0) {
                    return const SizedBox.shrink();
                  }
                  final reading = sortedReadings[value.toInt()];
                  final date = reading.timestamp;
                  // Only show some x-axis labels to avoid crowding
                  if (value.toInt() % _calculateInterval(sortedReadings.length) != 0) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      DateFormat('MM/dd HH:mm').format(date),
                      style: const TextStyle(
                        color: Colors.grey,
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  );
                },
                reservedSize: 28,
              ),
            ),
            leftTitles: AxisTitles(
              axisNameWidget: Text(
                widget.yAxisTitle,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
              sideTitles: SideTitles(
                showTitles: true,
                interval: 20,
                getTitlesWidget: (value, meta) {
                  return Text(
                    value.toInt().toString(),
                    style: const TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  );
                },
                reservedSize: 30,
              ),
            ),
            topTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(
              bottom: BorderSide(color: Color.fromRGBO(128, 128, 128, 0.4), width: 1),
              left: BorderSide(color: Color.fromRGBO(128, 128, 128, 0.4), width: 1),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              // backgroundColor: const Color.fromRGBO(96, 125, 139, 0.8),
              getTooltipItems: (touchedSpots) {
                return touchedSpots.map((spot) {
                  final reading = sortedReadings[spot.spotIndex];
                  final value = widget.dataSelector(reading);
                  final date = DateFormat('MM/dd/yyyy HH:mm').format(reading.timestamp);
                  return LineTooltipItem(
                    '$date\n${value.toStringAsFixed(1)}${widget.yAxisTitle.split(' ').last}',
                    const TextStyle(color: Colors.white),
                  );
                }).toList();
              },
            ),
            touchCallback: (event, response) {
              if (event is FlTapUpEvent) {
                setState(() {
                  if (response?.lineBarSpots != null && response!.lineBarSpots!.isNotEmpty) {
                    selectedSpotIndex = response.lineBarSpots!.first.spotIndex;
                  } else {
                    selectedSpotIndex = null;
                  }
                });
              }
            },
            handleBuiltInTouches: true,
          ),
          lineBarsData: [
            LineChartBarData(
              spots: List.generate(sortedReadings.length, (index) {
                final reading = sortedReadings[index];
                final value = widget.dataSelector(reading);
                return FlSpot(index.toDouble(), value);
              }),
              isCurved: true,
              color: widget.lineColor,
              barWidth: 3,
              isStrokeCapRound: true,
              dotData: FlDotData(
                show: true,
                getDotPainter: (spot, percent, barData, index) {
                  return FlDotCirclePainter(
                    radius: index == selectedSpotIndex ? 5 : 3,
                    color: index == selectedSpotIndex
                        ? widget.lineColor
                        : widget.lineColor.withAlpha(128), //  lineColor.withOpacity(0.5),
                    strokeWidth: 1,
                    strokeColor: Colors.white,
                  );
                },
              ),
              belowBarData: BarAreaData(
                show: true,
                color: widget.lineColor.withAlpha(51),
              ),
            ),
          ],
          minY: 0,
          maxY: 100,
        ),
      ),
    );
  }

  int _calculateInterval(int dataLength) {
    if (dataLength <= 5) return 1;
    if (dataLength <= 10) return 2;
    if (dataLength <= 20) return 4;
    return dataLength ~/ 5; // Show about 5 labels
  }

  @override
  void dispose() {
    super.dispose();
  }
}
