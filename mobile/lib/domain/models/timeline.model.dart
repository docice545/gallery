enum GroupAssetsBy { day, month, auto, none, year }

enum HeaderType { none, month, day, monthAndDay, year }

enum SortAssetsBy { taken, uploaded, deleted }

class Bucket {
  final int assetCount;

  /// Ordered, lightweight geometry for the virtualized photo mosaic. No media
  /// or full asset objects are loaded to measure rows. Other timelines may omit it.
  final List<double>? aspectRatios;

  const Bucket({required this.assetCount, this.aspectRatios});

  @override
  bool operator ==(covariant Bucket other) {
    return assetCount == other.assetCount;
  }

  @override
  int get hashCode => assetCount.hashCode;
}

class TimeBucket extends Bucket {
  final DateTime date;

  const TimeBucket({required this.date, required super.assetCount, super.aspectRatios});

  @override
  bool operator ==(covariant TimeBucket other) {
    return super == other && date == other.date;
  }

  @override
  int get hashCode => super.hashCode ^ date.hashCode;
}
