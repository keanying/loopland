import 'pose_source.dart';

/// Web: ML Kit has no web implementation → timer + manual counting.
PoseSource createPoseSource() => NoCameraPoseSource();
