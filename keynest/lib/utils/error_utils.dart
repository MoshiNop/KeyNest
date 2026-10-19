Never throws(Object e, [StackTrace? stackTrace]) {
  if (stackTrace != null) {
    Error.throwWithStackTrace(e, stackTrace);
  }
  throw e;
}
