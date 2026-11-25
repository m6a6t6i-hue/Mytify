import 'model.dart';
import 'repository_native.dart'
    if (dart.library.js_interop) 'repository_web.dart'
    as platform;

LibraryRepository createRepository() => platform.createRepository();
