// SPDX-License-Identifier: MPL-2.0

pragma solidity 0.6.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./mocks/MockERC20.sol";
import "./summa-tx/IRelay.sol";

contract RelayAuction is Ownable {
  using SafeMath for uint256;

  uint256 internal constant MAX_UINT = uint256(-1);
  uint256 internal constant MAX_MINT = 1e22; // max 10,000 $TRDL / day
  // duration of a slot in bitcoin blocks
  uint256 constant SLOT_LENGTH = 144;
  // number of blocks for active relayer to be behind, before some-one else can take over
  uint256 constant SNAP_THRESHOLD = 4;

  event NewRound(uint256 indexed slotStartBlock, address indexed slotWinner, int256 amount);
  event Bid(uint256 indexed slotStartBlock, address indexed relayer, int256 amount);
  event Snap(uint256 indexed slotStartBlock, address indexed oldWinner, address indexed newWinner);

  IERC20 rewardToken;
  uint256 rewardAmount;
  MockERC20 auctionToken;
  IRelay relay;

  struct Slot {
    address slotWinner;
    uint256 startBlock;
  }

  struct Bids {
    address bestBidder;
    int256 bestAmount;
  }

  Slot public currentRound;
  // mapping from slotStartBlock and address to bet amount
  mapping(uint256 => Bids) private bids;
  mapping(uint256 => mapping(address => int256)) private bidAmounts;
  bytes32 public lastAncestor;

  constructor(
    address _relay,
    address _rewardToken,
    uint256 _rewardAmount,
    address _auctionToken
  ) public {
    relay = IRelay(_relay);
    rewardToken = IERC20(_rewardToken);
    rewardAmount = _rewardAmount;
    auctionToken = MockERC20(_auctionToken);
  }

  function bestBid(uint256 slotStartBlock) external view returns (address) {
    return bids[slotStartBlock].bestBidder;
  }

  function _bid(uint256 slotStartBlock, int256 amount) internal {
    require(slotStartBlock % SLOT_LENGTH == 0, "not a start block");
    // check that betting for next round
    require(slotStartBlock > currentRound.startBlock, "can not bet for running rounds");
    int256 prevBet = bidAmounts[slotStartBlock][msg.sender];

    if (amount > 0) {
      require(amount > prevBet, "can not bet lower");
      uint256 pullValue = (prevBet < 0) ? uint256(amount) : uint256(amount - prevBet);
      // pull the funds
      auctionToken.transferFrom(msg.sender, address(this), pullValue);
    } else {
      require(amount < prevBet, "can not bet lower when negative");
    }
    emit Bid(slotStartBlock, msg.sender, amount);
    bidAmounts[slotStartBlock][msg.sender] = amount;
    int256 bestAmount = bids[slotStartBlock].bestAmount;
    if ((amount > bestAmount && amount >= 0) || (amount < 0 && amount < bestAmount)) {
      bids[slotStartBlock].bestBidder = msg.sender;
      bids[slotStartBlock].bestAmount = amount;
    }
  }

  function bid(uint256 slotStartBlock, int256 amount) external {
    _bid(slotStartBlock, amount);
  }

  function bidWithPermit(
    uint256 slotStartBlock,
    int256 amount,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external {
    auctionToken.permit(msg.sender, address(this), MAX_UINT, deadline, v, r, s);
    _bid(slotStartBlock, amount);
  }

  function withdrawBid(uint256 slotStartBlock) external {
    require(slotStartBlock % SLOT_LENGTH == 0, "not a start block");
    require(slotStartBlock <= currentRound.startBlock, "can not withdraw from future rounds");
    int256 amount = bidAmounts[slotStartBlock][msg.sender];
    require(amount > 0, "can not withdraw negative bids");
    bidAmounts[slotStartBlock][msg.sender] = 0;
    require(auctionToken.transfer(msg.sender, uint256(amount)), "could not transfer");
  }

  function _updateRound(uint256 _currentBestHeight) internal {
    // if we have gone into the next round
    Slot memory round = currentRound;
    if (round.startBlock + SLOT_LENGTH <= _currentBestHeight) {
      if (round.slotWinner != address(0)) {
        // pay out old slot owner
        rewardToken.transfer(round.slotWinner, rewardAmount);
        int256 bestAmount = bids[round.startBlock].bestAmount;
        if (bestAmount > 0) {
          auctionToken.transfer(round.slotWinner, uint256(bestAmount / 2));
        } else {
          uint256 mintAmount = uint256(-1 * bestAmount);
          mintAmount = (mintAmount > MAX_MINT) ? MAX_MINT : mintAmount;
          auctionToken.mint(round.slotWinner, mintAmount);
        }
      }

      // find new height
      uint256 newCurrent = (_currentBestHeight / SLOT_LENGTH) * SLOT_LENGTH;
      // find new winner
      address newWinner = bids[newCurrent].bestBidder;

      // set new current Round
      currentRound = Slot(newWinner, newCurrent);
      int256 winnerBidAmount = bidAmounts[newCurrent][newWinner];
      emit NewRound(newCurrent, newWinner, winnerBidAmount);

      if (newWinner != address(0)) {
        // set bet to 0, so winner can not withdraw
        bidAmounts[newCurrent][newWinner] = 0;
        if (winnerBidAmount > 0) {
          // burn auctionToken
          auctionToken.burn(uint256(winnerBidAmount / 2));
        }
      }
    }
  }

  function updateRound() public {
    bytes32 bestKnown = relay.getBestKnownDigest();
    uint256 currentBestHeight = relay.findHeight(bestKnown);
    _updateRound(currentBestHeight);
  }

  function _checkRound(bytes32 _ancestor) internal {
    uint256 relayHeight = relay.findHeight(_ancestor);

    Slot memory round = currentRound;
    bool isActiveSlot = round.startBlock <= relayHeight &&
      relayHeight < round.startBlock + SLOT_LENGTH;
    if (isActiveSlot) {
      if (
        msg.sender != round.slotWinner &&
        lastAncestor != 0x0 &&
        relayHeight.sub(relay.findHeight(lastAncestor)) >= SNAP_THRESHOLD
      ) {
        // snap the slot
        emit Snap(round.startBlock, round.slotWinner, msg.sender);
        currentRound.slotWinner = msg.sender;
      }
    }
    lastAncestor = _ancestor;

    // if we have left the slot, or it is filling up, roll slots forward
    if (!isActiveSlot || relayHeight >= round.startBlock + SLOT_LENGTH) {
      _updateRound(relayHeight);
    }
  }

  function markNewHeaviest(
    bytes32 _ancestor,
    bytes calldata _currentBest,
    bytes calldata _newBest,
    uint256 _limit
  ) external returns (bool) {
    _checkRound(_ancestor);
    require(
      relay.markNewHeaviest(_ancestor, _currentBest, _newBest, _limit),
      "mark new heaviest failed"
    );
  }

  /// simple proxy to relay, so frontend can use single address
  function getBestKnownDigest() external view returns (bytes32) {
    return relay.getBestKnownDigest();
  }

  /// simple proxy to relay, so frontend can use single address
  function getLastReorgCommonAncestor() external view returns (bytes32) {
    return relay.getLastReorgCommonAncestor();
  }

  /// simple proxy to relay, so frontend can use single address
  function findHeight(bytes32 _digest) external view returns (uint256) {
    return relay.findHeight(_digest);
  }

  /// simple proxy to relay, so frontend can use single address
  function isAncestor(
    bytes32 _ancestor,
    bytes32 _descendant,
    uint256 _limit
  ) external view returns (bool) {
    return relay.isAncestor(_ancestor, _descendant, _limit);
  }

  /// simple proxy to relay, so frontend can use single address
  function addHeaders(bytes calldata _anchor, bytes calldata _headers) external returns (bool) {
    require(relay.addHeaders(_anchor, _headers), "add header failed");
    return true;
  }

  /// simple proxy to relay, so frontend can use single address
  function addHeadersWithRetarget(
    bytes calldata _oldPeriodStartHeader,
    bytes calldata _oldPeriodEndHeader,
    bytes calldata _headers
  ) external returns (bool) {
    require(
      relay.addHeadersWithRetarget(_oldPeriodStartHeader, _oldPeriodEndHeader, _headers),
      "add header with retarget failed"
    );
    return true;
  }

  function setRewardAmount(uint256 newRewardAmount) external onlyOwner {
    rewardAmount = newRewardAmount;
  }

  function swipe(address tokenAddress) external onlyOwner {
    IERC20 token = IERC20(tokenAddress);
    token.transfer(owner(), token.balanceOf(address(this)));
  }
}
