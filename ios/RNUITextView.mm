#import "RNUITextView.h"
#import "RNUITextViewShadowNode.h"
#import "RNUITextViewComponentDescriptor.h"
#import "RNUITextViewChild.h"
#import <React/RCTConversions.h>
#import <QuartzCore/QuartzCore.h>

#import <react/renderer/textlayoutmanager/RCTAttributedTextUtils.h>
#import <react/renderer/components/RNUITextViewSpec/EventEmitters.h>
#import <react/renderer/components/RNUITextViewSpec/Props.h>
#import <react/renderer/components/RNUITextViewSpec/RCTComponentViewHelpers.h>
#import "RCTFabricComponentsPlugins.h"
#import <UIKit/UIMenu.h>
#import <UIKit/UIMenuBuilder.h>
#import <UIKit/UIMenuSystem.h>
#import <UIKit/UIMenuController.h>

using namespace facebook::react;

static NSString *const RNUITextViewCustomMenuIdentifier = @"xyz.bluesky.RNUITextView.custom";

static UIColor *RNUITextViewDefaultHighlightColor(void)
{
  return [UIColor colorWithRed:255.0/255.0 green:214.0/255.0 blue:102.0/255.0 alpha:0.45];
}

static UIImage *RNUITextViewColorCircleImage(UIColor *color)
{
  CGFloat size = 20.0; 
  CGRect rect = CGRectMake(0, 0, size, size);
  
  UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0.0);
  CGContextRef context = UIGraphicsGetCurrentContext();
  
  // Draw filled circle
  CGContextSetFillColorWithColor(context, color.CGColor);
  CGContextFillEllipseInRect(context, rect);
  
  // Add subtle border
  CGContextSetStrokeColorWithColor(context, [[UIColor grayColor] colorWithAlphaComponent:0.3].CGColor);
  CGContextSetLineWidth(context, 1.0);
  CGContextStrokeEllipseInRect(context, CGRectInset(rect, 0.5, 0.5));
  
  UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  return image;
}

@class RNUITextView;

@interface RNUITextViewInternal : UITextView <UITextViewDelegate>
@property (nonatomic, weak) RNUITextView *owner;
@end

@interface RNUITextView () <RCTRNUITextViewViewProtocol, UIGestureRecognizerDelegate>

- (void)configureMenuWithBuilder:(id<UIMenuBuilder>)builder API_AVAILABLE(ios(13.0));
- (void)handleMenuActionWithIdentifier:(NSString *)identifier;
- (void)clearSelectionIfNecessary;
- (void)onTextSelectionDidChange;
- (void)showColorPickerMenu;
- (UIColor *)colorFromHexString:(NSString *)hexString;

@end

@implementation RNUITextViewInternal

- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder API_AVAILABLE(ios(13.0))
{
  [super buildMenuWithBuilder:builder];
  [self.owner configureMenuWithBuilder:builder];
}

- (void)textViewDidChangeSelection:(UITextView *)textView
{
  // Forward selection changes to owner so it can rebuild menu
  [self.owner onTextSelectionDidChange];
}

@end

@implementation RNUITextView{
  UIView * _view;
  RNUITextViewInternal * _textView;
  RNUITextViewShadowNode::ConcreteState::Shared _state;
  NSArray<NSDictionary<NSString *, NSString *> *> *_menuItems;
  facebook::react::RNUITextViewMenuBehavior _menuBehavior;
  NSArray<NSDictionary *> *_highlightRanges;  // Each dict: @{@"range": NSValue, @"color": UIColor}
  UIColor *_highlightColor;  // Fallback/default color
  NSMutableArray<CALayer *> *_highlightLayers;
  NSRange _pendingHighlightRange;  // Store range for color picker
  BOOL _showColorPicker;           // Flag to switch menu mode
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
    _textView.delegate = _textView; // Set delegate to self so we get selection change callbacks
    _textView.scrollEnabled = false;
  _textView.editable = false;
  _textView.textContainerInset = UIEdgeInsetsZero;
  _textView.textContainer.lineFragmentPadding = 0;
  [self addSubview:_textView];
  _highlightColor = RNUITextViewDefaultHighlightColor();
  _highlightLayers = [NSMutableArray array];
  _pendingHighlightRange = NSMakeRange(NSNotFound, 0);
  _showColorPicker = NO;

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

  // Cancel any pending highlight updates
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateHighlightLayers) object:nil];

  // Reset the frame to zero so that when it properly lays out on the next use
  _textView.frame = CGRectZero;
  _textView.attributedText = nil;
  _menuItems = nil;
  _highlightRanges = nil;
  _highlightColor = nil;
  _pendingHighlightRange = NSMakeRange(NSNotFound, 0);
  _showColorPicker = NO;
  
  // Remove menu hide observer
  [[NSNotificationCenter defaultCenter] removeObserver:self name:UIMenuControllerDidHideMenuNotification object:nil];
  
  [self clearHighlightLayers];
}

- (UIColor *)colorFromHexString:(NSString *)hexString
{
  if (!hexString || hexString.length == 0) {
    return RNUITextViewDefaultHighlightColor();
  }
  
  // Remove '#' if present
  NSString *cleanHex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
  
  if (cleanHex.length != 8) {
    return RNUITextViewDefaultHighlightColor();
  }
  
  unsigned rgbValue = 0;
  NSScanner *scanner = [NSScanner scannerWithString:cleanHex];
  if (![scanner scanHexInt:&rgbValue]) {
    return RNUITextViewDefaultHighlightColor();
  }
  
  // Extract RGBA components (RRGGBBAA format)
  CGFloat red = ((rgbValue & 0xFF000000) >> 24) / 255.0;
  CGFloat green = ((rgbValue & 0x00FF0000) >> 16) / 255.0;
  CGFloat blue = ((rgbValue & 0x0000FF00) >> 8) / 255.0;
  CGFloat alpha = (rgbValue & 0x000000FF) / 255.0;
  
  return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

- (void)drawRect:(CGRect)rect
{
  if (!_state) {
    return;
  }

  const auto &props = *std::static_pointer_cast<RNUITextViewProps const>(_props);

  const auto attrString = _state->getData().attributedString;
  const auto convertedAttrString = RCTNSAttributedStringFromAttributedString(attrString);

  _textView.attributedText = convertedAttrString;
  _textView.frame = _view.frame;
  
  // Ensure layout is complete before building highlight layers
  [_textView setNeedsLayout];
  [_textView layoutIfNeeded];
  
  // Rebuild highlights immediately - layout is guaranteed to be ready after layoutIfNeeded
  // Safety checks in updateHighlightLayers ensure we handle edge cases
  if (_highlightRanges && _highlightRanges.count > 0) {
  [self updateHighlightLayers];
  }

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

  // Always update menu items (even if unchanged) to handle view recycling
  // After recycling, _menuItems is nil, so we need to set it even if props haven't changed
  bool needsMenuUpdate = menuChanged || (_menuItems == nil && newViewProps.menuItems.size() > 0) || oldViewProps.menuBehavior != newViewProps.menuBehavior;

  if (needsMenuUpdate) {
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
      // Force menu rebuild to ensure custom actions appear after view recycling
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
      // Also check color changes
      std::string oldColor = oldRange.color;
      std::string newColor = newRange.color;
      if (oldColor != newColor) {
        highlightRangesChanged = true;
        break;
      }
    }
  }

  // Always update highlight ranges (even if unchanged) to handle view recycling
  // After recycling, _highlightRanges is nil, so we need to set it even if props haven't changed
  bool needsHighlightUpdate = highlightRangesChanged || (_highlightRanges == nil && newViewProps.highlightRanges.size() > 0);

  if (needsHighlightUpdate) {
    NSMutableArray<NSDictionary *> *ranges = [NSMutableArray arrayWithCapacity:newViewProps.highlightRanges.size()];
    for (const auto &range : newViewProps.highlightRanges) {
      NSInteger start = MAX(range.start, 0);
      NSInteger end = MAX(range.end, start);
      if (end <= start) {
        continue;
      }
      NSUInteger length = (NSUInteger)(end - start);
      NSRange nsRange = NSMakeRange((NSUInteger)start, length);
      
      // Extract color from range, convert to UIColor
      UIColor *color = _highlightColor; // Default fallback
      if (!range.color.empty()) {
        NSString *colorHex = [NSString stringWithUTF8String:range.color.c_str()];
        color = [self colorFromHexString:colorHex];
      }
      
      NSDictionary *rangeDict = @{
        @"range": [NSValue valueWithRange:nsRange],
        @"color": color
      };
      [ranges addObject:rangeDict];
    }

    _highlightRanges = ranges.count > 0 ? [ranges copy] : nil;

    // Always trigger drawRect to rebuild highlights after text layout
    // Also try to rebuild immediately if text is already available (covers view recycling case)
    [self setNeedsDisplay];
    
    // If text is already set, rebuild highlights immediately
    // This handles the case where updateProps runs after drawRect has already set the text
    if (_textView.attributedText && _textView.attributedText.length > 0 && !CGRectIsEmpty(_textView.bounds)) {
      [_textView setNeedsLayout];
      [_textView layoutIfNeeded];
    [self updateHighlightLayers];
    }
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

- (void)showColorPickerMenu
{
  if (!_showColorPicker) {
    return;
  }
  
  // Verify selection still matches pending range
  NSRange currentRange = _textView.selectedRange;
  if (_pendingHighlightRange.location != NSNotFound) {
    BOOL rangeMatches = (currentRange.location == _pendingHighlightRange.location && 
                        currentRange.length == _pendingHighlightRange.length);
    if (!rangeMatches) {
      _showColorPicker = NO;
      _pendingHighlightRange = NSMakeRange(NSNotFound, 0);
      return;
    }
  }
  
  // Make text view first responder to show menu
  if (!_textView.isFirstResponder) {
    [_textView becomeFirstResponder];
  }
  
  // Use UIMenuController to show menu at selection
  UIMenuController *menuController = [UIMenuController sharedMenuController];
  if (menuController.isMenuVisible) {
    [menuController setMenuVisible:NO animated:NO];
  }
  
  // Calculate rect for selection
  NSRange selectedRange = _textView.selectedRange;
  if (selectedRange.location != NSNotFound && selectedRange.length > 0) {
    UITextRange *textRange = [_textView textRangeFromPosition:[_textView positionFromPosition:_textView.beginningOfDocument offset:selectedRange.location]
                                                     toPosition:[_textView positionFromPosition:_textView.beginningOfDocument offset:NSMaxRange(selectedRange)]];
    if (textRange) {
      CGRect selectionRect = [_textView firstRectForRange:textRange];
      CGRect targetRect = [self convertRect:selectionRect fromView:_textView];
      
      [menuController setTargetRect:targetRect inView:self];
      [menuController setMenuVisible:YES animated:YES];
      
      // Monitor menu dismissal - reset color picker when menu hides
      // Use notification to detect when menu is dismissed
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(menuDidHide:)
                                                   name:UIMenuControllerDidHideMenuNotification
                                                 object:nil];
    }
  }
}

- (void)menuDidHide:(NSNotification *)notification
{
  // Reset color picker when menu is dismissed
  if (_showColorPicker) {
    _showColorPicker = NO;
    _pendingHighlightRange = NSMakeRange(NSNotFound, 0);
  }
  [[NSNotificationCenter defaultCenter] removeObserver:self name:UIMenuControllerDidHideMenuNotification object:nil];
}

- (void)onTextSelectionDidChange
{
  NSRange currentRange = _textView.selectedRange;
  
  // If color picker is showing, check if selection changed to a different range
  // If it's a different range, reset color picker to show regular menu
  if (_showColorPicker) {
    // Compare with pending range - if different, user selected new text
    if (_pendingHighlightRange.location != NSNotFound) {
      BOOL isDifferentRange = (currentRange.location != _pendingHighlightRange.location || 
                               currentRange.length != _pendingHighlightRange.length);
      
      if (isDifferentRange && currentRange.length > 0) {
        // User selected different text - reset color picker
        _showColorPicker = NO;
        _pendingHighlightRange = NSMakeRange(NSNotFound, 0);
      } else if (currentRange.length == 0) {
        // Selection cleared (user tapped outside) - reset color picker
        _showColorPicker = NO;
        _pendingHighlightRange = NSMakeRange(NSNotFound, 0);
      }
      // If selection matches pending range, keep color picker active (user might be interacting with menu)
    }
  } else {
    // Not showing color picker - reset pending range
    _pendingHighlightRange = NSMakeRange(NSNotFound, 0);
  }
  
  // Force menu rebuild when text selection changes to ensure custom actions appear
  // This handles cases where menu disappears after view recycling
  if (@available(iOS 13.0, *)) {
    if (_menuItems && _menuItems.count > 0) {
      [[UIMenuSystem mainSystem] setNeedsRebuild];
    }
  }
}

- (void)configureMenuWithBuilder:(id<UIMenuBuilder>)builder API_AVAILABLE(ios(13.0))
{
  if (!builder) {
    return;
  }

  [builder removeMenuForIdentifier:RNUITextViewCustomMenuIdentifier];

  NSMutableArray<UIAction *> *actions = [NSMutableArray array];
  __weak RNUITextView *weakSelf = self;

  if (_showColorPicker) {
    // Remove all system menu items when showing color picker
    // Remove standard edit menu (Copy, Select All, etc.)
    [builder removeMenuForIdentifier:UIMenuStandardEdit];
    
    // Remove services menus (Look Up, Translate, Learn) - available iOS 16+
    if (@available(iOS 16.0, *)) {
      [builder removeMenuForIdentifier:UIMenuLookup];
      [builder removeMenuForIdentifier:UIMenuLearn];
    }
    
    // Remove Share menu
    [builder removeMenuForIdentifier:UIMenuShare];
    
    // Remove all other menus from root - iterate through and remove system menus
    // This ensures only our color picker is shown
    UIMenu *rootMenu = [builder menuForIdentifier:UIMenuRoot];
    if (rootMenu && rootMenu.children) {
      NSArray<UIMenuElement *> *childMenus = rootMenu.children;
      for (UIMenuElement *element in childMenus) {
        // Only process UIMenu elements
        if ([element isKindOfClass:[UIMenu class]]) {
          UIMenu *childMenu = (UIMenu *)element;
          NSString *menuId = childMenu.identifier;
          // Keep our custom menu, remove everything else
          if (menuId && ![menuId isEqualToString:RNUITextViewCustomMenuIdentifier]) {
            [builder removeMenuForIdentifier:menuId];
          }
        }
      }
    }
    
    // Show color picker menu
    NSArray *colorOptions = @[
      @{@"id": @"color:FFD66673", @"hex": @"#FFD66673"},  // Yellow
      @{@"id": @"color:90EE9073", @"hex": @"#90EE9073"},  // Green
      @{@"id": @"color:ADD8E673", @"hex": @"#ADD8E673"},  // Blue
      @{@"id": @"color:FFB6C173", @"hex": @"#FFB6C173"},  // Pink
      @{@"id": @"color:DDA0DD73", @"hex": @"#DDA0DD73"}   // Purple
    ];
    
    for (NSDictionary *colorOption in colorOptions) {
      NSString *colorId = colorOption[@"id"];
      NSString *hexColor = colorOption[@"hex"];
      UIColor *color = [self colorFromHexString:hexColor];
      UIImage *circleImage = RNUITextViewColorCircleImage(color);
      
      UIAction *action = [UIAction actionWithTitle:@""
                                             image:circleImage
                                        identifier:nil
                                           handler:^(__kindof UIAction * _Nonnull _) {
                                             [weakSelf handleMenuActionWithIdentifier:colorId];
                                           }];
      [actions addObject:action];
    }
  } else {
    // Show regular menu
    if (!_menuItems || _menuItems.count == 0) {
      return;
    }

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

  // Check if this is "highlight" action
  if ([identifier isEqualToString:@"highlight"]) {
    _pendingHighlightRange = selectedRange;
    _showColorPicker = YES;
    
    // Emit to JS (creates highlight with last-used color)
    const int start = selectedRange.location == NSNotFound ? -1 : static_cast<int>(selectedRange.location);
    const int end = selectedRange.location == NSNotFound ? -1 : static_cast<int>(NSMaxRange(selectedRange));
    
    facebook::react::RNUITextViewEventEmitter::OnMenuAction event{
      static_cast<int>(self.tag),
      std::string("highlight"),
      std::string(selectedText.UTF8String ?: ""),
      start,
      end
    };
    emitter->onMenuAction(std::move(event));
    
    // Rebuild menu to show color picker (DON'T clear selection)
    // Keep selection active so menu can be shown again
    if (@available(iOS 13.0, *)) {
      [[UIMenuSystem mainSystem] setNeedsRebuild];
      
      // Show menu again immediately with color picker
      // Use performSelector to delay slightly so menu rebuild completes
      [self performSelector:@selector(showColorPickerMenu) withObject:nil afterDelay:0.1];
    }
    return;
  }
  
  // Check if this is a color selection
  if ([identifier hasPrefix:@"color:"]) {
    
    // Store range before resetting
    NSRange storedRange = _pendingHighlightRange;
    
    _showColorPicker = NO;
    _pendingHighlightRange = NSMakeRange(NSNotFound, 0);
    
    // Remove menu hide observer since we're handling dismissal here
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIMenuControllerDidHideMenuNotification object:nil];
    
    // Emit color change event with stored range
    const int start = storedRange.location == NSNotFound ? -1 : static_cast<int>(storedRange.location);
    const int end = storedRange.location == NSNotFound ? -1 : static_cast<int>(NSMaxRange(storedRange));
    
    facebook::react::RNUITextViewEventEmitter::OnMenuAction event{
      static_cast<int>(self.tag),
      std::string([identifier UTF8String]),
      std::string(""),
      start,
      end
    };
    emitter->onMenuAction(std::move(event));
    
    [self clearSelectionIfNecessary];
    return;
  }
  
  // For other actions, proceed normally
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

- (void)clearHighlightLayers
{
  if (!_highlightLayers.count) {
    return;
  }

  for (CALayer *layer in _highlightLayers) {
    [layer removeFromSuperlayer];
  }
  [_highlightLayers removeAllObjects];
}

- (void)updateHighlightLayers
{
  [self clearHighlightLayers];

  if (!_highlightRanges || _highlightRanges.count == 0 || !_textView) {
    return;
  }

  UITextView *textView = _textView;
  
  // Ensure attributedText is set and layout is ready
  if (!textView.attributedText || textView.attributedText.length == 0) {
    return;
  }
  
  const CGRect textViewBounds = textView.bounds;
  if (CGRectIsEmpty(textViewBounds) || CGRectIsNull(textViewBounds)) {
    return;
  }

  // Ensure layout is complete before enumerating glyph ranges
  [textView.layoutManager ensureLayoutForTextContainer:textView.textContainer];
  
  // Double-check that layout is actually ready by ensuring glyphs exist
  NSRange fullRange = NSMakeRange(0, textView.attributedText.length);
  if (fullRange.length == 0) {
    return;
  }
  
  NSRange glyphRange = [textView.layoutManager glyphRangeForCharacterRange:fullRange actualCharacterRange:nil];
  if (glyphRange.location == NSNotFound || glyphRange.length == 0) {
    // Layout not ready yet, will be retried on next drawRect
    return;
  }

  const UIEdgeInsets inset = textView.textContainerInset;
  static const CGFloat horizontalPadding = 2.0;
  static const CGFloat verticalPadding = 1.5;
  static const CGFloat cornerRadius = 6.0;
  static const CGFloat lineMergeTolerance = 0.5; // Pixels tolerance for "same line"

  // Group rects by color - each color gets its own layer
  // Key: color description (for comparison), Value: array of rect dictionaries with line info
  NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *rectsByColor = [NSMutableDictionary dictionary];

  for (NSDictionary *rangeDict in _highlightRanges) {
    NSValue *rangeValue = rangeDict[@"range"];
    UIColor *rangeColor = rangeDict[@"color"];
    if (!rangeValue || !rangeColor) {
      continue;
    }
    
    NSRange range = [rangeValue rangeValue];
    if (range.location == NSNotFound || range.length == 0) {
      continue;
    }

    // Use color's description as key for grouping
    NSString *colorKey = [rangeColor description];

    [textView.layoutManager enumerateEnclosingRectsForGlyphRange:range
                                      withinSelectedGlyphRange:NSMakeRange(NSNotFound, 0)
                                               inTextContainer:textView.textContainer
                                                    usingBlock:^(CGRect rect, BOOL * _Nonnull stop) {
      if (CGRectIsEmpty(rect) || CGRectIsNull(rect)) {
        return;
      }

      CGRect padded = CGRectInset(rect, -horizontalPadding, -verticalPadding);
      padded.origin.x += inset.left;
      padded.origin.y += inset.top;
      CGRect clipped = CGRectIntersection(padded, textViewBounds);
      if (CGRectIsEmpty(clipped) || CGRectIsNull(clipped)) {
        return;
      }

      // Get or create array for this color
      NSMutableArray<NSDictionary *> *colorRects = rectsByColor[colorKey];
      if (!colorRects) {
        colorRects = [NSMutableArray array];
        rectsByColor[colorKey] = colorRects;
      }

      // Store rect with its Y position for line grouping
      [colorRects addObject:@{
        @"rect": [NSValue valueWithCGRect:clipped],
        @"color": rangeColor
      }];
    }];
  }

  // Build separate path for each color
  for (NSString *colorKey in rectsByColor) {
    NSMutableArray<NSDictionary *> *colorRects = rectsByColor[colorKey];
    if (colorRects.count == 0) {
      continue;
    }

    UIColor *layerColor = colorRects[0][@"color"];
    
    // Group rects by line (Y position) for this color
    NSMutableArray<NSMutableArray<NSValue *> *> *rectsByLine = [NSMutableArray array];
    
    for (NSDictionary *rectDict in colorRects) {
      NSValue *rectValue = rectDict[@"rect"];
      CGRect clipped = [rectValue CGRectValue];
      
      // Find which line group this rect belongs to (same Y position)
      NSMutableArray<NSValue *> *lineGroup = nil;
      for (NSMutableArray<NSValue *> *group in rectsByLine) {
        if (group.count > 0) {
          CGRect firstRect = [group[0] CGRectValue];
          if (fabs(CGRectGetMidY(clipped) - CGRectGetMidY(firstRect)) < lineMergeTolerance) {
            lineGroup = group;
            break;
          }
        }
      }
      
      if (!lineGroup) {
        lineGroup = [NSMutableArray array];
        [rectsByLine addObject:lineGroup];
      }
      
      [lineGroup addObject:rectValue];
    }

    // Build path for this color: merge adjacent rects on same line
    UIBezierPath *colorPath = [UIBezierPath bezierPath];

    for (NSMutableArray<NSValue *> *lineGroup in rectsByLine) {
      if (lineGroup.count == 0) {
        continue;
      }

      // Sort rects by X position within this line
      [lineGroup sortUsingComparator:^NSComparisonResult(NSValue *val1, NSValue *val2) {
        CGRect rect1 = [val1 CGRectValue];
        CGRect rect2 = [val2 CGRectValue];
        if (rect1.origin.x < rect2.origin.x) {
          return NSOrderedAscending;
        } else if (rect1.origin.x > rect2.origin.x) {
          return NSOrderedDescending;
        }
        return NSOrderedSame;
      }];

      // Merge adjacent rects on same line
      NSMutableArray<NSValue *> *mergedRects = [NSMutableArray array];
      CGRect currentMerged = [lineGroup[0] CGRectValue];

      for (NSUInteger i = 1; i < lineGroup.count; i++) {
        CGRect nextRect = [lineGroup[i] CGRectValue];
        CGFloat gap = nextRect.origin.x - CGRectGetMaxX(currentMerged);
        
        if (gap <= cornerRadius * 2) {
          currentMerged = CGRectUnion(currentMerged, nextRect);
        } else {
          [mergedRects addObject:[NSValue valueWithCGRect:currentMerged]];
          currentMerged = nextRect;
        }
      }
      [mergedRects addObject:[NSValue valueWithCGRect:currentMerged]];

      // Add merged rects to path
      for (NSValue *value in mergedRects) {
        CGRect rect = [value CGRectValue];
        UIBezierPath *rounded = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:cornerRadius];
        [colorPath appendPath:rounded];
      }
    }

    const CGRect highlightBounds = colorPath.bounds;
    if (CGRectIsEmpty(highlightBounds) || CGRectIsNull(highlightBounds)) {
      continue;
    }

    // Create layer for this color
    CAShapeLayer *highlightLayer = [CAShapeLayer layer];
    highlightLayer.frame = textViewBounds;
    highlightLayer.path = colorPath.CGPath;
    highlightLayer.fillColor = layerColor.CGColor;
    highlightLayer.zPosition = -1;

    [textView.layer addSublayer:highlightLayer];
    [_highlightLayers addObject:highlightLayer];
  }
}

Class<RCTComponentViewProtocol> RNUITextViewCls(void)
{
  return RNUITextView.class;
}

@end
