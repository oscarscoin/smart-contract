/*
OSCARS COIN (OSC)

https://oscarscoin.com
*/


// SPDX-License-Identifier: No License
pragma solidity 0.8.19;

import "./ERC20.sol";
import "./ERC20Burnable.sol";
import "./Ownable2Step.sol";
import "./TokenRecover.sol";
import "./ERC20Permit.sol";
import "./Initializable.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Router01.sol";
import "./IUniswapV2Router02.sol";

contract OSCARS_COIN is ERC20, ERC20Burnable, Ownable2Step, TokenRecover, ERC20Permit, Initializable {
    
    IERC20 public feeToken;

    uint16 public swapThresholdRatio;
    
    uint256 private _maintenancePending;

    address public maintenanceAddress;
    uint16[3] public maintenanceFees;

    mapping (address => bool) public isExcludedFromFees;

    uint16[3] public totalFees;
    bool private _swapping;

    IUniswapV2Router02 public routerV2;
    address public pairV2;
    mapping (address => bool) public AMMPairs;
 
    event SwapThresholdUpdated(uint16 swapThresholdRatio);

    event maintenanceAddressUpdated(address maintenanceAddress);
    event maintenanceFeesUpdated(uint16 buyFee, uint16 sellFee, uint16 transferFee);
    event maintenanceFeeSent(address recipient, uint256 amount);

    event ExcludeFromFees(address indexed account, bool isExcluded);

    event RouterV2Updated(address indexed routerV2);
    event AMMPairsUpdated(address indexed AMMPair, bool isPair);
 
    constructor()
        ERC20(unicode"OSCARS COIN", unicode"OSC") 
        ERC20Permit(unicode"OSCARS COIN")
    {
        address supplyRecipient = 0xfB57730967820759d5ab187aa4e56c8eb917c535;
        
        updateSwapThreshold(50);

        maintenanceAddressSetup(0xfB57730967820759d5ab187aa4e56c8eb917c535);
        maintenanceFeesSetup(200, 200, 200);

        excludeFromFees(supplyRecipient, true);
        excludeFromFees(address(this), true); 

        _mint(supplyRecipient, 1500000000000 * (10 ** decimals()) / 10);
        _transferOwnership(0xfB57730967820759d5ab187aa4e56c8eb917c535);
    }
    
    /*
        This token is not upgradeable, but uses both the constructor and initializer for post-deployment setup.
    */
    function initialize(address _feeToken, address _router) initializer external {
        _updateFeeToken(_feeToken);
        _updateRouterV2(_router);
    }

    receive() external payable {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
    
    function _updateFeeToken(address feeTokenAddress) private {
        feeToken = IERC20(feeTokenAddress);
    }

    function _sendInOtherTokens(address to, uint256 amount) private returns (bool) {
        return feeToken.transfer(to, amount);
    }
    
    function _swapTokensForOtherTokens(uint256 tokenAmount) private {
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = routerV2.WETH();
        path[2] = address(feeToken);
        
        _approve(address(this), address(routerV2), tokenAmount);
        
        routerV2.swapExactTokensForTokensSupportingFeeOnTransferTokens(tokenAmount, 0, path, address(this), block.timestamp);
    }

    function updateSwapThreshold(uint16 _swapThresholdRatio) public onlyOwner {
        require(_swapThresholdRatio > 0 && _swapThresholdRatio <= 500, "SwapThreshold: Cannot exceed limits from 0.01% to 5% for new swap threshold");
        swapThresholdRatio = _swapThresholdRatio;
        
        emit SwapThresholdUpdated(_swapThresholdRatio);
    }

    function getSwapThresholdAmount() public view returns (uint256) {
        return balanceOf(pairV2) * swapThresholdRatio / 10000;
    }

    function getAllPending() public view returns (uint256) {
        return 0 + _maintenancePending;
    }

    function maintenanceAddressSetup(address _newAddress) public onlyOwner {
        require(_newAddress != address(0), "TaxesDefaultRouterWallet: Wallet tax recipient cannot be a 0x0 address");

        maintenanceAddress = _newAddress;
        excludeFromFees(_newAddress, true);

        emit maintenanceAddressUpdated(_newAddress);
    }

    function maintenanceFeesSetup(uint16 _buyFee, uint16 _sellFee, uint16 _transferFee) public onlyOwner {
        totalFees[0] = totalFees[0] - maintenanceFees[0] + _buyFee;
        totalFees[1] = totalFees[1] - maintenanceFees[1] + _sellFee;
        totalFees[2] = totalFees[2] - maintenanceFees[2] + _transferFee;
        require(totalFees[0] <= 2500 && totalFees[1] <= 2500 && totalFees[2] <= 2500, "TaxesDefaultRouter: Cannot exceed max total fee of 25%");

        maintenanceFees = [_buyFee, _sellFee, _transferFee];

        emit maintenanceFeesUpdated(_buyFee, _sellFee, _transferFee);
    }

    function excludeFromFees(address account, bool isExcluded) public onlyOwner {
        isExcludedFromFees[account] = isExcluded;
        
        emit ExcludeFromFees(account, isExcluded);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (!_swapping && amount > 0 && to != address(routerV2) && !isExcludedFromFees[from] && !isExcludedFromFees[to]) {
            uint256 fees = 0;
            uint8 txType = 3;
            
            if (AMMPairs[from]) {
                if (totalFees[0] > 0) txType = 0;
            }
            else if (AMMPairs[to]) {
                if (totalFees[1] > 0) txType = 1;
            }
            else if (totalFees[2] > 0) txType = 2;
            
            if (txType < 3) {
                
                fees = amount * totalFees[txType] / 10000;
                amount -= fees;
                
                _maintenancePending += fees * maintenanceFees[txType] / totalFees[txType];

                
            }

            if (fees > 0) {
                super._transfer(from, address(this), fees);
            }
        }
        
        bool canSwap = getAllPending() >= getSwapThresholdAmount() && balanceOf(pairV2) > 0;
        
        if (!_swapping && !AMMPairs[from] && from != address(routerV2) && canSwap) {
            _swapping = true;
            
            if (false || _maintenancePending > 0) {
                uint256 token2Swap = 0 + _maintenancePending;
                bool success = false;

                _swapTokensForOtherTokens(token2Swap);
                uint256 tokensReceived = feeToken.balanceOf(address(this));
                
                uint256 maintenancePortion = tokensReceived * _maintenancePending / token2Swap;
                if (maintenancePortion > 0) {
                    success = _sendInOtherTokens(maintenanceAddress, maintenancePortion);
                    if (success) {
                        emit maintenanceFeeSent(maintenanceAddress, maintenancePortion);
                    }
                }
                _maintenancePending = 0;

            }

            _swapping = false;
        }

        super._transfer(from, to, amount);
        
    }

    function _updateRouterV2(address router) private {
        routerV2 = IUniswapV2Router02(router);
        pairV2 = IUniswapV2Factory(routerV2.factory()).createPair(address(this), routerV2.WETH());
        
        _setAMMPair(pairV2, true);

        emit RouterV2Updated(router);
    }

    function setAMMPair(address pair, bool isPair) external onlyOwner {
        require(pair != pairV2, "DefaultRouter: Cannot remove initial pair from list");

        _setAMMPair(pair, isPair);
    }

    function _setAMMPair(address pair, bool isPair) private {
        AMMPairs[pair] = isPair;

        if (isPair) { 
        }

        emit AMMPairsUpdated(pair, isPair);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        override
    {
        super._beforeTokenTransfer(from, to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount)
        internal
        override
    {
        super._afterTokenTransfer(from, to, amount);
    }
}
