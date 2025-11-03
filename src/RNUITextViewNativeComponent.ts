import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent'
import type {ViewProps} from 'react-native'
import type {
  BubblingEventHandler,
  Int32,
  WithDefault,
} from 'react-native/Libraries/Types/CodegenTypes'

interface TargetedEvent {
  target: Int32
}

interface TextLayoutEvent extends TargetedEvent {
  lines: string[]
}

type EllipsizeMode = 'head' | 'middle' | 'tail' | 'clip'

type MenuBehavior = 'augment' | 'replace'

interface MenuItem {
  id: string
  title: string
}

interface MenuActionEvent extends TargetedEvent {
  id: string
  selectedText: string
  rangeStart: Int32
  rangeEnd: Int32
}

interface HighlightRange {
  start: Int32
  end: Int32
}

interface NativeProps extends ViewProps {
  numberOfLines?: Int32
  allowFontScaling?: WithDefault<boolean, true>
  ellipsizeMode?: WithDefault<EllipsizeMode, 'tail'>
  selectable?: boolean
  menuItems?: ReadonlyArray<MenuItem>
  menuBehavior?: WithDefault<MenuBehavior, 'augment'>
  onTextLayout?: BubblingEventHandler<TextLayoutEvent>
  onMenuAction?: BubblingEventHandler<MenuActionEvent>
  highlightRanges?: ReadonlyArray<HighlightRange>
}

export default codegenNativeComponent<NativeProps>('RNUITextView', {
  excludedPlatforms: ['android'],
})
