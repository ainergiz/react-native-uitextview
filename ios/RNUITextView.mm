#import "RNUITextView.h"
#import "RNUITextViewShadowNode.h"
#import "RNUITextViewComponentDescriptor.h"
#import "RNUITextViewChild.h"
#import <React/RCTConversions.h>

#import <react/renderer/textlayoutmanager/RCTAttributedTextUtils.h>
#import <react/renderer/components/RNUITextViewSpec/EventEmitters.h>
#import <react/renderer/components/RNUITextViewSpec/Props.h>
#import <react/renderer/components/RNUITextViewSpec/RCTComponentViewHelpers.h>
#import "RCTFabricComponentsPlugins.h"
#import <UIKit/UIMenu.h>
#import <UIKit/UIMenuBuilder.h>
#import <UIKit/UIMenuSystem.h>

using namespace facebook::react;

static NSString *const RNUITextViewCustomMenuIdentifier = @"xyz.bluesky.RNUITextView.custom";

static UIColor *RNUITextViewDefaultHighlightColor(void)
{
  return [UIColor colorWithRed:255.0/255.0 green:214.0/255.0 blue:102.0/255.0 alpha:0.45];
}

@class RNUITextView;

@interface RNUITextViewInternal : UITextView
@property (nonatomic, weak) RNUITextView *owner;
@end

@interface RNUITextView () <RCTRNUITextViewViewProtocol, UIGestureRecognizerDelegate>

- (void)configureMenuWithBuilder:(id<UIMenuBuilder>)builder API_AVAILABLE(ios(13.0));
- (void)handleMenuActionWithIdentifier:(NSString *)identifier;
- (void)clearSelectionIfNecessary;

@end

@implementation RNUITextViewInternal

- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder API_AVAILABLE(ios(13.0))
{
  [super buildMenuWithBuilder:builder];
  [self.owner configureMenuWithBuilder:builder];
}

@end

@implementation RNUITextView{
  UIView * _view;
  RNUITextViewInternal * _textView;
  RNUITextViewShadowNode::ConcreteState::Shared _state;
  NSArray<NSDictionary<NSString *, NSString *> *> *_menuItems;
  facebook::react::RNUITextViewMenuBehavior _menuBehavior;
  NSArray<NSValue *> *_highlightRanges;
  UIColor *_highlightColor;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<RNUITextViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const RNUITextViewProps>();
    _props = defaultProps;

    _view = [[UIView alloc] init];
    self.contentView = _view;
    self.clipsToBounds = true;

    _textView = [[RNUITextViewInternal alloc] init];
    _textView.owner = self;
    _textView.scrollEnabled = false;
  _textView.editable = false;
  _textView.textContainerInset = UIEdgeInsetsZero;
  _textView.textContainer.lineFragmentPadding = 0;
  [self addSubview:_textView];
  _highlightColor = RNUITextViewDefaultHighlightColor();

    const auto longPressGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                          action:@selector(handleLongPressIfNecessary:)];
    longPressGestureRecognizer.delegate = self;

    const auto pressGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(handlePressIfNecessary:)];
    pressGestureRecognizer.delegate = self;
    [pressGestureRecognizer requireGestureRecognizerToFail:longPressGestureRecognizer];

    [_textView addGestureRecognizer:pressGestureRecognizer];
    [_textView addGestureRecognizer:longPressGestureRecognizer];
  }

  return self;
}

// See RCTParagraphComponentView
- (void)prepareForRecycle
{
  [super prepareForRecycle];
  _state.reset();

  // Reset the frame to zero so that when it properly lays out on the next use
  _textView.frame = CGRectZero;
  _textView.attributedText = nil;
  _menuItems = nil;
  _highlightRanges = nil;
  _highlightColor = nil;
}

- (void)drawRect:(CGRect)rect
{
  if (!_state) {
    return;
  }

  const auto &props = *std::static_pointer_cast<RNUITextViewProps const>(_props);

  const auto attrString = _state->getData().attributedString;
  const auto convertedAttrString = RCTNSAttributedStringFromAttributedString(attrString);

  NSAttributedString *attributedStringToApply = convertedAttrString;
  if (_highlightRanges.count > 0) {
    NSMutableAttributedString *mutableString = [convertedAttrString mutableCopy];
    UIColor *color = _highlightColor ?: RNUITextViewDefaultHighlightColor();
    const NSUInteger stringLength = mutableString.length;

    for (NSValue *value in _highlightRanges) {
      NSRange range = value.rangeValue;
      if (range.location == NSNotFound || range.length == 0) {
        continue;
      }

      if (range.location >= stringLength) {
        continue;
      }

      NSUInteger clampedLength = MIN(range.length, stringLength - range.location);
      if (clampedLength == 0) {
        continue;
      }

      [mutableString addAttribute:NSBackgroundColorAttributeName
                            value:color
                            range:NSMakeRange(range.location, clampedLength)];
    }

    attributedStringToApply = mutableString;
  }

  _textView.attributedText = attributedStringToApply;
  _textView.frame = _view.frame;

  const auto lines = new std::vector<std::string>();
  [_textView.layoutManager enumerateLineFragmentsForGlyphRange:NSMakeRange(0, convertedAttrString.string.length) usingBlock:^(CGRect rect,
                                                                                              CGRect usedRect,
                                                                                              NSTextContainer * _Nonnull textContainer,
                                                                                              NSRange glyphRange,
                                                                                              BOOL * _Nonnull stop) {
    const auto charRange = [self->_textView.layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:nil];
    const auto line = [self->_textView.text substringWithRange:charRange];

    if (props.numberOfLines && props.numberOfLines > 0 && lines->size() < props.numberOfLines) {
      lines->push_back(line.UTF8String);
    }
  }];

  if (_eventEmitter != nullptr) {
    std::dynamic_pointer_cast<const facebook::react::RNUITextViewEventEmitter>(_eventEmitter)
    ->onTextLayout(facebook::react::RNUITextViewEventEmitter::OnTextLayout{static_cast<int>(self.tag), *lines});
  };
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &oldViewProps = *std::static_pointer_cast<RNUITextViewProps const>(_props);
  const auto &newViewProps = *std::static_pointer_cast<RNUITextViewProps const>(props);

  if (oldViewProps.numberOfLines != newViewProps.numberOfLines) {
    _textView.textContainer.maximumNumberOfLines = newViewProps.numberOfLines;
  }

  if (oldViewProps.selectable != newViewProps.selectable) {
    _textView.selectable = newViewProps.selectable;
  }

  if (oldViewProps.allowFontScaling != newViewProps.allowFontScaling) {
    if (@available(iOS 11.0, *)) {
      _textView.adjustsFontForContentSizeCategory = newViewProps.allowFontScaling;
    }
  }

  if (oldViewProps.ellipsizeMode != newViewProps.ellipsizeMode) {
    if (newViewProps.ellipsizeMode == RNUITextViewEllipsizeMode::Head) {
      _textView.textContainer.lineBreakMode = NSLineBreakMode::NSLineBreakByTruncatingHead;
    } else if (newViewProps.ellipsizeMode == RNUITextViewEllipsizeMode::Middle) {
      _textView.textContainer.lineBreakMode = NSLineBreakMode::NSLineBreakByTruncatingMiddle;
    } else if (newViewProps.ellipsizeMode == RNUITextViewEllipsizeMode::Tail) {
      _textView.textContainer.lineBreakMode = NSLineBreakMode::NSLineBreakByTruncatingTail;
    } else if (newViewProps.ellipsizeMode == RNUITextViewEllipsizeMode::Clip) {
      _textView.textContainer.lineBreakMode = NSLineBreakMode::NSLineBreakByClipping;
    }
  }

  // I'm not sure if this is really the right way to handle this style. This means that the entire _view_ the text
  // is in will have this background color applied. To apply it just to a particular part of a string, you'd need
  // to do <Text><Text style={{backgroundColor: 'blue'}}>Hello</Text></Text>.
  // This is how the base <Text> component works though, so we'll go with it for now. Can change later if we want.
  if (oldViewProps.backgroundColor != newViewProps.backgroundColor) {
    _textView.backgroundColor = RCTUIColorFromSharedColor(newViewProps.backgroundColor);
  }

  bool menuChanged = oldViewProps.menuItems.size() != newViewProps.menuItems.size();
  if (!menuChanged) {
    for (size_t i = 0; i < newViewProps.menuItems.size(); ++i) {
      const auto &oldItem = oldViewProps.menuItems[i];
      const auto &newItem = newViewProps.menuItems[i];
      if (oldItem.id != newItem.id || oldItem.title != newItem.title) {
        menuChanged = true;
        break;
      }
    }
  }

  if (menuChanged || oldViewProps.menuBehavior != newViewProps.menuBehavior) {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *items = [NSMutableArray array];

    for (const auto &item : newViewProps.menuItems) {
      NSString *identifier = [NSString stringWithUTF8String:item.id.c_str()];
      if (identifier.length == 0) {
        continue;
      }
      NSString *title = [NSString stringWithUTF8String:item.title.c_str()];

      NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithCapacity:2];
      entry[@"id"] = identifier;
      if (title.length > 0) {
        entry[@"title"] = title;
      }
      [items addObject:[entry copy]];
    }

    _menuItems = items.count > 0 ? [items copy] : nil;
    _menuBehavior = newViewProps.menuBehavior;

    if (@available(iOS 13.0, *)) {
      [[UIMenuSystem mainSystem] setNeedsRebuild];
    }
  }

  bool highlightRangesChanged = oldViewProps.highlightRanges.size() != newViewProps.highlightRanges.size();
  if (!highlightRangesChanged) {
    for (size_t i = 0; i < newViewProps.highlightRanges.size(); ++i) {
      const auto &oldRange = oldViewProps.highlightRanges[i];
      const auto &newRange = newViewProps.highlightRanges[i];
      if (oldRange.start != newRange.start || oldRange.end != newRange.end) {
        highlightRangesChanged = true;
        break;
      }
    }
  }

  if (highlightRangesChanged) {
    NSMutableArray<NSValue *> *ranges = [NSMutableArray arrayWithCapacity:newViewProps.highlightRanges.size()];
    for (const auto &range : newViewProps.highlightRanges) {
      NSInteger start = MAX(range.start, 0);
      NSInteger end = MAX(range.end, start);
      if (end <= start) {
        continue;
      }
      NSUInteger length = (NSUInteger)(end - start);
      NSRange nsRange = NSMakeRange((NSUInteger)start, length);
      [ranges addObject:[NSValue valueWithRange:nsRange]];
    }

    _highlightRanges = ranges.count > 0 ? [ranges copy] : nil;

    [self setNeedsDisplay];
  }

  [super updateProps:props oldProps:oldProps];
}

// See RCTParagraphComponentView
- (void)updateState:(const facebook::react::State::Shared &)state oldState:(const facebook::react::State::Shared &)oldState
{
  _state = std::static_pointer_cast<const RNUITextViewShadowNode::ConcreteState>(state);
  [self setNeedsDisplay];
}

#pragma mark - Menu Handling

- (void)configureMenuWithBuilder:(id<UIMenuBuilder>)builder API_AVAILABLE(ios(13.0))
{
  if (!builder) {
    return;
  }

  [builder removeMenuForIdentifier:RNUITextViewCustomMenuIdentifier];

  if (!_menuItems || _menuItems.count == 0) {
    return;
  }

  NSMutableArray<UIAction *> *actions = [NSMutableArray arrayWithCapacity:_menuItems.count];
  __weak RNUITextView *weakSelf = self;

  for (NSDictionary<NSString *, NSString *> *item in _menuItems) {
    NSString *identifier = item[@"id"];
    if (identifier.length == 0) {
      continue;
    }

    NSString *title = item[@"title"] ?: identifier;
    NSString *capturedIdentifier = [identifier copy];

    UIAction *action = [UIAction actionWithTitle:title
                                           image:nil
                                       identifier:nil
                                          handler:^(__kindof UIAction * _Nonnull _) {
                                            [weakSelf handleMenuActionWithIdentifier:capturedIdentifier];
                                          }];
    [actions addObject:action];
  }

  if (actions.count == 0) {
    return;
  }

  if (_menuBehavior == facebook::react::RNUITextViewMenuBehavior::Replace) {
    [builder removeMenuForIdentifier:UIMenuStandardEdit];
  }

  UIMenu *customMenu = [UIMenu menuWithTitle:@""
                                       image:nil
                                   identifier:RNUITextViewCustomMenuIdentifier
                                      options:UIMenuOptionsDisplayInline
                                     children:actions];

  [builder insertChildMenu:customMenu atStartOfMenuForIdentifier:UIMenuRoot];
}

- (void)handleMenuActionWithIdentifier:(NSString *)identifier
{
  if (identifier.length == 0 || _eventEmitter == nullptr) {
    return;
  }

  NSRange selectedRange = _textView.selectedRange;
  NSString *selectedText = @"";
  if (selectedRange.location != NSNotFound && NSMaxRange(selectedRange) <= _textView.text.length) {
    selectedText = [_textView.text substringWithRange:selectedRange];
  }

  auto emitter = std::dynamic_pointer_cast<const facebook::react::RNUITextViewEventEmitter>(_eventEmitter);
  if (emitter == nullptr) {
    return;
  }

  const int start = selectedRange.location == NSNotFound ? -1 : static_cast<int>(selectedRange.location);
  const int end = selectedRange.location == NSNotFound ? -1 : static_cast<int>(NSMaxRange(selectedRange));

  facebook::react::RNUITextViewEventEmitter::OnMenuAction event{
    static_cast<int>(self.tag),
    std::string(identifier.UTF8String ?: ""),
    std::string(selectedText.UTF8String ?: ""),
    start,
    end
  };
  emitter->onMenuAction(std::move(event));

  [self clearSelectionIfNecessary];
}

// MARK: - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
  return YES;
}

// MARK: - Touch handling

- (CGPoint)getLocationOfPress:(UIGestureRecognizer*)sender
{
  return [sender locationInView:_textView];
}

- (RNUITextViewChild*)getTouchChild:(CGPoint)location
{
  const auto charIndex = [_textView.layoutManager characterIndexForPoint:location
                                                         inTextContainer:_textView.textContainer
                                fractionOfDistanceBetweenInsertionPoints:nil
  ];

  int currIndex = -1;
  for (UIView* child in self.subviews) {
    if (![child isKindOfClass:[RNUITextViewChild class]]) {
      continue;
    }

    RNUITextViewChild* textChild = (RNUITextViewChild*)child;

    // This is UTF16 code units!!
    currIndex += textChild.text.length;

    if (charIndex <= currIndex) {
      return textChild;
    }
  }

  return nil;
}

- (void)handlePressIfNecessary:(UITapGestureRecognizer*)sender
{
  const auto location = [self getLocationOfPress:sender];
  const auto child = [self getTouchChild:location];

  if (child) {
    [child onPress];
  } else {
    [self clearSelectionIfNecessary];
  }
}

- (void)handleLongPressIfNecessary:(UILongPressGestureRecognizer*)sender
{
  const auto location = [self getLocationOfPress:sender];
  const auto child = [self getTouchChild:location];

  if (child) {
    [child onLongPress];
  }
}

- (void)clearSelectionIfNecessary
{
  NSRange range = _textView.selectedRange;
  if (range.length > 0) {
    _textView.selectedRange = NSMakeRange(0, 0);
  }
  if (_textView.isFirstResponder) {
    [_textView resignFirstResponder];
  }
}

Class<RCTComponentViewProtocol> RNUITextViewCls(void)
{
  return RNUITextView.class;
}

@end
