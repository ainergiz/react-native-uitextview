import React from 'react'
import {
  Platform,
  StyleSheet,
  Text as RNText,
  type NativeSyntheticEvent,
  type TextProps,
  type ViewStyle,
} from 'react-native'
import RNUITextViewChildNativeComponent from './RNUITextViewChildNativeComponent'
import RNUITextViewNativeComponent from './RNUITextViewNativeComponent'
import {flattenStyles} from './util'

const TextAncestorContext = React.createContext<[boolean, ViewStyle]>([
  false,
  StyleSheet.create({}),
])

const textDefaults: TextProps = {
  allowFontScaling: true,
  selectable: true,
}

export type UITextViewMenuItem = {
  id: string
  title: string
}

export type UITextViewMenuBehavior = 'augment' | 'replace'

type MenuActionNativeEvent = {
  id: string
  selectedText: string
  rangeStart: number
  rangeEnd: number
}

export type UITextViewMenuActionNativeEvent = MenuActionNativeEvent
export type UITextViewMenuActionEvent = NativeSyntheticEvent<MenuActionNativeEvent>

export type UITextViewHighlightRange = {
  start: number
  end: number
}

export type UITextViewProps = TextProps & {
  uiTextView?: boolean
  menuItems?: ReadonlyArray<UITextViewMenuItem>
  menuBehavior?: UITextViewMenuBehavior
  onMenuAction?: (event: NativeSyntheticEvent<MenuActionNativeEvent>) => void
  highlightRanges?: ReadonlyArray<UITextViewHighlightRange>
}

const useTextAncestorContext = () => React.useContext(TextAncestorContext)

function UITextViewChild({
  style,
  children,
  menuItems,
  menuBehavior,
  onMenuAction,
  highlightRanges,
  ...rest
}: UITextViewProps) {
  const [isAncestor, rootStyle] = useTextAncestorContext()

  // Flatten the styles, and apply the root styles when needed
  const flattenedStyle = React.useMemo(
    () => flattenStyles(rootStyle, style),
    [rootStyle, style],
  )

  if (!isAncestor) {
    return (
      <TextAncestorContext.Provider value={[true, flattenedStyle]}>
        <RNUITextViewNativeComponent
          {...textDefaults}
          {...rest}
          menuItems={menuItems}
          menuBehavior={menuBehavior}
          onMenuAction={onMenuAction}
          highlightRanges={highlightRanges}
          // ellipsizeMode={rest.ellipsizeMode ?? rest.lineBreakMode ?? 'tail'}
          style={[flattenedStyle]}
          // @ts-ignore TODO: align RN native event typing
          onPress={undefined}
          onLongPress={undefined}>
          {React.Children.toArray(children).map((c, index) => {
            if (React.isValidElement(c)) {
              return c
            } else if (typeof c === 'string' || typeof c === 'number') {
              return (
                // @ts-ignore TODO: narrow child text typing
                <RNUITextViewChildNativeComponent
                  key={index}
                  style={flattenedStyle}
                  text={c.toString()}
                  {...rest}
                />
              )
            }
            return null
          })}
        </RNUITextViewNativeComponent>
      </TextAncestorContext.Provider>
    )
  } else {
    return (
      <>
        {React.Children.toArray(children).map((c, index) => {
          if (React.isValidElement(c)) {
            return c
          } else if (typeof c === 'string' || typeof c === 'number') {
            return (
              // @ts-expect-error @TODO fix this type
              <RNUITextViewChildNativeComponent
                key={index}
                style={flattenedStyle}
                text={c.toString()}
                {...rest}
              />
            )
          }

          return null
        })}
      </>
    )
  }
}

function UITextViewInner(
  props: UITextViewProps,
) {
  const [isAncestor] = useTextAncestorContext()

  // Even if the uiTextView prop is set, we can still default to using
  // normal selection (i.e. base RN text) if the text doesn't need to be
  // selectable
  if ((!props.selectable || !props.uiTextView) && !isAncestor) {
    return <RNText {...props} />
  }
  return <UITextViewChild {...props} />
}

export function UITextView(props: UITextViewProps) {
  if (Platform.OS !== 'ios') {
    return <RNText {...props} />
  }
  return <UITextViewInner {...props} />
}
