class KeyNestTabNavigationHandler {
  const KeyNestTabNavigationHandler({
    required this.isSelectionActive,
    required this.exitSelection,
    required this.isSearchActive,
    required this.clearSearch,
  });

  final bool Function() isSelectionActive;
  final void Function() exitSelection;
  final bool Function() isSearchActive;
  final void Function() clearSearch;
}
