//
//  ModuleGridView.swift
//  kicklab
//

import SwiftUI

struct ModuleGridView: View {
    let modules: [TrainingModule]
    let onSelect: (TrainingModule) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: HomeSurface.gridSpacing),
              count: typeSize.isAccessibilitySize ? 2 : 3)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: HomeSurface.gridSpacing) {
            ForEach(modules) { module in
                ModuleCardView(module: module) {
                    onSelect(module)
                }
            }
        }
    }
}
